// Playback: a render worker fills a lock-free ring ahead of the playhead; the
// audio thread only copies out of it. See jammer_engine.h for the thread rules.
//
// Seeking without blocking the audio thread:
//   1. jm_engine_play stores the start frame and bumps `requestSeq`.
//   2. The worker stops writing, publishes the start in `parkedStart`, then
//      `parkedSeq`.
//   3. The audio thread sees the new `parkedSeq`, drops what's in the ring,
//      rebases its playhead and answers with `ackSeq`.
//   4. The worker renders from the new start.
// Only the worker writes the ring and `writePos`; only the audio thread moves
// `readPos`. Neither ever waits for the other.

#include "internal.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <pthread.h>
#include <thread>

namespace jm {

constexpr int32_t kMaxChannels = 32;
constexpr int64_t kBlock = 1024;

struct Engine {
    int32_t channels;
    double sampleRate;
    // Ring of interleaved frames. `ringData` is fixed after creation.
    std::vector<float> ringStorage;
    float *ringData = nullptr;
    uint64_t capacity = 0; // frames, power of two
    uint64_t mask = 0;
    std::atomic<uint64_t> writePos{0};
    std::atomic<uint64_t> readPos{0};

    // Transport requests (any thread → worker).
    std::atomic<uint64_t> requestSeq{0};
    std::atomic<int64_t> requestFrame{0};
    std::atomic<bool> playing{false};

    // Worker → audio thread.
    std::atomic<uint64_t> parkedSeq{0};
    std::atomic<int64_t> parkedStart{0};
    std::atomic<int64_t> endFrame{0};

    // Audio thread → others.
    std::atomic<uint64_t> ackSeq{0};
    std::atomic<int64_t> playhead{0};
    std::atomic<int64_t> underruns{0};
    std::atomic<float> gain{1.0f};
    std::atomic<float> peaks[kMaxChannels];
    std::atomic<uint64_t> renderedSinceAck{0};

    // Audio-thread-only state.
    uint64_t rtSeq = 0;
    int64_t rtBase = 0;
    int64_t rtConsumed = 0;
    bool rtStarted = false;

    // Plan handoff (UI ↔ worker; the worker isn't realtime, so a mutex is fine).
    std::mutex planMutex;
    std::shared_ptr<Plan> plan;

    std::atomic<bool> quit{false};
    std::thread worker;

    void run();
};

void Engine::run() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    Renderer renderer(channels);
    std::vector<float> block(size_t(kBlock * channels));
    uint64_t workerSeq = 0;
    int64_t renderFrame = 0;
    bool streaming = false;
    while (!quit.load(std::memory_order_acquire)) {
        const uint64_t seq = requestSeq.load(std::memory_order_acquire);
        if (seq != workerSeq) {
            // Park: stop writing and hand the new start to the audio thread.
            parkedStart.store(requestFrame.load(std::memory_order_acquire), std::memory_order_relaxed);
            parkedSeq.store(seq, std::memory_order_release);
            workerSeq = seq;
            streaming = false;
        }
        if (!streaming) {
            if (ackSeq.load(std::memory_order_acquire) != workerSeq) {
                std::this_thread::sleep_for(std::chrono::microseconds(500));
                continue;
            }
            renderFrame = parkedStart.load(std::memory_order_relaxed);
            streaming = true;
        }
        std::shared_ptr<Plan> current;
        {
            std::lock_guard<std::mutex> lock(planMutex);
            current = plan;
        }
        endFrame.store(current ? current->length : 0, std::memory_order_relaxed);
        const uint64_t w = writePos.load(std::memory_order_relaxed);
        const uint64_t r = readPos.load(std::memory_order_acquire);
        const uint64_t space = capacity - (w - r);
        if (space < uint64_t(kBlock)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }
        const int64_t n = kBlock;
        if (current && current->finalized) renderer.render(*current, renderFrame, n, block.data());
        else std::fill(block.begin(), block.end(), 0.0f);
        // A newer request arrived while rendering: drop this block.
        if (requestSeq.load(std::memory_order_acquire) != workerSeq) continue;
        for (int64_t i = 0; i < n; ++i) {
            std::memcpy(ringData + ((w + uint64_t(i)) & mask) * uint64_t(channels), block.data() + i * channels,
                        size_t(channels) * sizeof(float));
        }
        writePos.store(w + uint64_t(n), std::memory_order_release);
        renderedSinceAck.fetch_add(uint64_t(n), std::memory_order_relaxed);
        renderFrame += n;
    }
}

inline void raise_peak(std::atomic<float> &peak, float v) JM_NONBLOCKING {
    float old = peak.load(std::memory_order_relaxed);
    while (v > old && !peak.compare_exchange_weak(old, v, std::memory_order_relaxed)) {
    }
}

void pull(Engine &e, float *const *outs, int32_t channels, int32_t frames) JM_NONBLOCKING {
    const uint64_t parked = e.parkedSeq.load(std::memory_order_acquire);
    if (parked != e.rtSeq) {
        e.readPos.store(e.writePos.load(std::memory_order_acquire), std::memory_order_release);
        e.rtBase = e.parkedStart.load(std::memory_order_relaxed);
        e.rtConsumed = 0;
        e.rtStarted = false;
        e.rtSeq = parked;
        e.renderedSinceAck.store(0, std::memory_order_relaxed);
        e.playhead.store(e.rtBase, std::memory_order_relaxed);
        e.ackSeq.store(parked, std::memory_order_release);
    }
    int64_t n = 0;
    const bool playing = e.playing.load(std::memory_order_acquire) && e.rtSeq == e.requestSeq.load(std::memory_order_acquire);
    if (playing) {
        const uint64_t r = e.readPos.load(std::memory_order_relaxed);
        const uint64_t avail = e.writePos.load(std::memory_order_acquire) - r;
        n = int64_t(std::min<uint64_t>(avail, uint64_t(frames)));
        const int64_t end = e.endFrame.load(std::memory_order_relaxed);
        const int64_t head = e.rtBase + e.rtConsumed;
        if (end > 0 && head + n > end) n = std::max<int64_t>(0, end - head);
        const float g = e.gain.load(std::memory_order_relaxed);
        const int32_t ec = e.channels;
        for (int32_t ch = 0; ch < channels; ++ch) {
            float *o = outs[ch];
            float peak = 0.0f;
            if (ch < ec) {
                for (int64_t i = 0; i < n; ++i) {
                    const float v = e.ringData[((r + uint64_t(i)) & e.mask) * uint64_t(ec) + uint64_t(ch)] * g;
                    o[i] = v;
                    const float a = v < 0 ? -v : v;
                    if (a > peak) peak = a;
                }
            } else {
                for (int64_t i = 0; i < n; ++i) o[i] = 0.0f;
            }
            for (int64_t i = n; i < frames; ++i) o[i] = 0.0f;
            if (ch < kMaxChannels) raise_peak(e.peaks[ch], peak);
        }
        e.readPos.store(r + uint64_t(n), std::memory_order_release);
        e.rtConsumed += n;
        e.playhead.store(e.rtBase + e.rtConsumed, std::memory_order_relaxed);
        if (n > 0) e.rtStarted = true;
        if (end > 0 && e.rtBase + e.rtConsumed >= end) {
            e.playing.store(false, std::memory_order_release);
        } else if (n < frames && e.rtStarted) {
            e.underruns.fetch_add(1, std::memory_order_relaxed);
        }
    } else {
        for (int32_t ch = 0; ch < channels; ++ch) {
            for (int32_t i = 0; i < frames; ++i) outs[ch][i] = 0.0f;
        }
    }
}

} // namespace jm

using namespace jm;

struct jm_engine {
    Engine e;
};

extern "C" {

jm_engine *jm_engine_create(int32_t channels, double sample_rate, int32_t ring_frames) {
    auto *h = new jm_engine();
    Engine &e = h->e;
    e.channels = std::clamp(channels, 1, kMaxChannels);
    e.sampleRate = sample_rate;
    uint64_t cap = 1;
    while (cap < uint64_t(std::max<int32_t>(ring_frames, int32_t(kBlock * 2)))) cap <<= 1;
    e.capacity = cap;
    e.mask = cap - 1;
    e.ringStorage.assign(size_t(cap * uint64_t(e.channels)), 0.0f);
    e.ringData = e.ringStorage.data();
    for (auto &p : e.peaks) p.store(0.0f);
    e.worker = std::thread([&e] { e.run(); });
    return h;
}

void jm_engine_destroy(jm_engine *engine) {
    if (!engine) return;
    engine->e.quit.store(true, std::memory_order_release);
    if (engine->e.worker.joinable()) engine->e.worker.join();
    delete engine;
}

void jm_engine_set_plan(jm_engine *engine, jm_plan *plan) {
    std::shared_ptr<Plan> p = plan ? plan->ptr : nullptr;
    std::lock_guard<std::mutex> lock(engine->e.planMutex);
    engine->e.plan = std::move(p);
}

void jm_engine_play(jm_engine *engine, int64_t frame) {
    Engine &e = engine->e;
    e.requestFrame.store(std::max<int64_t>(0, frame), std::memory_order_release);
    e.requestSeq.fetch_add(1, std::memory_order_acq_rel);
    e.playing.store(true, std::memory_order_release);
}

void jm_engine_stop(jm_engine *engine) { engine->e.playing.store(false, std::memory_order_release); }
bool jm_engine_is_playing(const jm_engine *engine) { return engine->e.playing.load(std::memory_order_acquire); }
int64_t jm_engine_playhead(const jm_engine *engine) { return engine->e.playhead.load(std::memory_order_relaxed); }
void jm_engine_set_gain(jm_engine *engine, float gain) { engine->e.gain.store(gain, std::memory_order_relaxed); }
int64_t jm_engine_underruns(const jm_engine *engine) { return engine->e.underruns.load(std::memory_order_relaxed); }

float jm_engine_take_peak(jm_engine *engine, int32_t channel) {
    if (channel < 0 || channel >= kMaxChannels) return 0.0f;
    return engine->e.peaks[channel].exchange(0.0f, std::memory_order_relaxed);
}

bool jm_engine_seek_settled(const jm_engine *engine) {
    return engine->e.ackSeq.load(std::memory_order_acquire) == engine->e.requestSeq.load(std::memory_order_acquire);
}

bool jm_engine_wait_primed(jm_engine *engine, int32_t timeout_ms) {
    Engine &e = engine->e;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        if (e.ackSeq.load(std::memory_order_acquire) == e.requestSeq.load(std::memory_order_acquire) &&
            e.writePos.load(std::memory_order_acquire) - e.readPos.load(std::memory_order_acquire) >= e.capacity / 2) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}

void jm_engine_pull(jm_engine *engine, float *const *outs, int32_t channels, int32_t frames) JM_NONBLOCKING {
    pull(engine->e, outs, channels, frames);
}

OSStatus jm_engine_au_render(void *ref_con, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time_stamp,
                             UInt32 bus, UInt32 frames, AudioBufferList *io_data) JM_NONBLOCKING {
    (void)flags;
    (void)time_stamp;
    (void)bus;
    if (!io_data) return noErr;
    float *outs[kMaxChannels];
    const int32_t n = int32_t(std::min<UInt32>(io_data->mNumberBuffers, UInt32(kMaxChannels)));
    for (int32_t i = 0; i < n; ++i) outs[i] = static_cast<float *>(io_data->mBuffers[i].mData);
    pull(static_cast<jm_engine *>(ref_con)->e, outs, n, int32_t(frames));
    return noErr;
}

} // extern "C"
