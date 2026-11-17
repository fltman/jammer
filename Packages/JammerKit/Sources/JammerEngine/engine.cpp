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
constexpr int32_t kMaxSlots = 64;
constexpr int64_t kBlock = 1024;
/// The block the worker makes while the ring is kept short.
constexpr int64_t kBrief = 256;

/// One device output channel: interleaved channel `channel` of buffer `buffer`,
/// fed from engine channel `source`.
struct OutputSlot {
    int32_t buffer = 0;
    int32_t channel = 0;
    int32_t source = 0;
};

/// One destination for `pull`: `frames` floats `stride` apart from `base`.
struct Out {
    float *base;
    int32_t stride;
    int32_t source; // engine channel, or -1 for silence
};

/// Resamples the plan from the project rate to the device rate in the worker
/// (AudioConverter, mastering quality). Never used on the audio thread.
class Resampler {
public:
    void setLive(LiveTrims *live) { renderer_.live = live; }
    Resampler(int32_t channels, double from, double to) : channels_(channels), renderer_(channels) {
        AudioStreamBasicDescription in{};
        in.mFormatID = kAudioFormatLinearPCM;
        in.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        in.mChannelsPerFrame = UInt32(channels);
        in.mBitsPerChannel = 32;
        in.mBytesPerFrame = in.mBytesPerPacket = UInt32(4 * channels);
        in.mFramesPerPacket = 1;
        AudioStreamBasicDescription out = in;
        in.mSampleRate = from;
        out.mSampleRate = to;
        if (AudioConverterNew(&in, &out, &converter_) != noErr) {
            converter_ = nullptr;
            return;
        }
        UInt32 complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
        AudioConverterSetProperty(converter_, kAudioConverterSampleRateConverterComplexity, sizeof(complexity), &complexity);
        UInt32 quality = kAudioConverterQuality_Max;
        AudioConverterSetProperty(converter_, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality);
        input_.assign(size_t(kBlock * channels), 0.0f);
    }
    ~Resampler() {
        if (converter_) AudioConverterDispose(converter_);
    }
    Resampler(const Resampler &) = delete;
    Resampler &operator=(const Resampler &) = delete;

    bool ok() const { return converter_ != nullptr; }

    void seek(int64_t frame) {
        frame_ = frame;
        AudioConverterReset(converter_);
    }

    /// Fills up to `frames` device frames into `out`; returns how many.
    int64_t render(const std::shared_ptr<Plan> &plan, int64_t frames, float *out) {
        plan_ = plan.get();
        AudioBufferList list{};
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = UInt32(channels_);
        list.mBuffers[0].mDataByteSize = UInt32(frames * channels_ * 4);
        list.mBuffers[0].mData = out;
        UInt32 packets = UInt32(frames);
        AudioConverterFillComplexBuffer(converter_, fill, this, &packets, &list, nullptr);
        plan_ = nullptr;
        return int64_t(packets);
    }

private:
    static OSStatus fill(AudioConverterRef, UInt32 *packets, AudioBufferList *data, AudioStreamPacketDescription **, void *user) {
        auto *self = static_cast<Resampler *>(user);
        const int64_t n = std::min<int64_t>(int64_t(*packets), kBlock);
        if (self->plan_ && self->plan_->finalized) self->renderer_.render(*self->plan_, self->frame_, n, self->input_.data());
        else std::fill(self->input_.begin(), self->input_.end(), 0.0f);
        self->frame_ += n;
        data->mNumberBuffers = 1;
        data->mBuffers[0].mNumberChannels = UInt32(self->channels_);
        data->mBuffers[0].mDataByteSize = UInt32(n * self->channels_ * 4);
        data->mBuffers[0].mData = self->input_.data();
        *packets = UInt32(n);
        return noErr;
    }

    int32_t channels_;
    Renderer renderer_;
    AudioConverterRef converter_ = nullptr;
    std::vector<float> input_;
    const Plan *plan_ = nullptr;
    int64_t frame_ = 0;
};

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
    /// For test copies of the app: nothing reaches the device (set after all metering), and what would
    /// have is counted, so a test can measure what was "heard" without a sound in the room.
    std::atomic<bool> silent{false};
    std::atomic<bool> tap{false};
    std::atomic<double> tapEnergy{0.0};
    std::atomic<int64_t> tapFrames{0};
    std::atomic<float> gain{1.0f};
    /// How many frames ahead of the playhead the worker keeps the ring; 0: all of it.
    std::atomic<int64_t> ahead{0};
    /// How many times a new plan has gone on from the one before it without a reset.
    std::atomic<int64_t> continued{0};
    /// Levels under a hand, and what was put on (see LiveTrims).
    LiveTrims live;
    std::atomic<float> peaks[kMaxChannels];
    std::atomic<uint64_t> renderedSinceAck{0};

    // Device side. `outRate` is the rate the ring runs at; when it differs from
    // `sampleRate` the worker resamples. `parkedRatio` (project frames per device
    // frame) is published with each park, before `parkedSeq`.
    std::atomic<double> outRate{0};
    std::atomic<double> parkedRatio{1.0};
    // Where each device channel takes its audio from. Written only while the
    // device is stopped (jm_engine_set_output); read by the IOProc.
    OutputSlot slots[kMaxSlots];
    std::atomic<int32_t> slotCount{0};

    // Audio-thread-only state.
    uint64_t rtSeq = 0;
    int64_t rtBase = 0;
    int64_t rtConsumed = 0; // device frames since rtBase
    double rtRatio = 1.0;
    bool rtStarted = false;

    // Plan handoff (UI ↔ worker; the worker isn't realtime, so a mutex is fine).
    std::mutex planMutex;
    std::shared_ptr<Plan> plan;

    std::atomic<bool> quit{false};
    std::thread worker;
    double resamplerRate = 0; // worker only

    void run();
};

void Engine::run() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    Renderer renderer(channels);
    renderer.live = &live;
    std::vector<float> block(size_t(kBlock * channels));
    std::unique_ptr<Resampler> resampler;
    uint64_t workerSeq = 0;
    int64_t renderFrame = 0;
    double parkRate = 0;
    bool streaming = false;
    std::shared_ptr<Plan> last;
    while (!quit.load(std::memory_order_acquire)) {
        const uint64_t seq = requestSeq.load(std::memory_order_acquire);
        if (seq != workerSeq) {
            // Park: stop writing and hand the new start (and rate) to the audio thread.
            const double r = outRate.load(std::memory_order_acquire);
            parkRate = r > 0 ? r : sampleRate;
            parkedRatio.store(sampleRate / parkRate, std::memory_order_relaxed);
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
            if (parkRate == sampleRate) {
                resampler.reset();
            } else {
                if (!resampler || resamplerRate != parkRate) {
                    resampler = std::make_unique<Resampler>(channels, sampleRate, parkRate);
                    resampler->setLive(&live);
                    resamplerRate = parkRate;
                    if (!resampler->ok()) resampler.reset();
                }
                if (resampler) resampler->seek(renderFrame);
            }
            streaming = true;
        }
        std::shared_ptr<Plan> current;
        {
            std::lock_guard<std::mutex> lock(planMutex);
            current = plan;
        }
        // A new plan while playing: where it has the same shape as the one before (a mute, a level, a
        // pan), it goes on from that one's state instead of starting afresh, so that no tail is cut.
        if (current != last) {
            if (current && last && streaming && continuePlan(*current, *last)) continued.fetch_add(1, std::memory_order_relaxed);
            last = current;
        }
        endFrame.store(current ? current->length : 0, std::memory_order_relaxed);
        const uint64_t w = writePos.load(std::memory_order_relaxed);
        const uint64_t r = readPos.load(std::memory_order_acquire);
        // How far ahead of the playhead the ring is kept: all of it, or, while a hand is on a control,
        // only `ahead` frames, so that what the control does is heard at once. Going from one to the
        // other changes only when the next block is made: no frame is skipped, none is made twice, and
        // nothing that makes the sound is touched.
        const int64_t want = ahead.load(std::memory_order_relaxed);
        const bool brief = want > 0 && uint64_t(want) + uint64_t(kBlock) < capacity;
        int64_t n = brief ? kBrief : kBlock;
        const uint64_t limit = brief ? uint64_t(std::max<int64_t>(want, kBrief)) : capacity;
        if ((w - r) + uint64_t(n) > limit) {
            std::this_thread::sleep_for(brief ? std::chrono::microseconds(300) : std::chrono::microseconds(1000));
            continue;
        }
        if (resampler) {
            n = resampler->render(current, n, block.data());
            if (n <= 0) continue;
        } else if (current && current->finalized) {
            renderer.render(*current, renderFrame, n, block.data());
        } else {
            std::fill(block.begin(), block.end(), 0.0f);
        }
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

/// The audio thread's whole job: take what the worker rendered and write it to
/// `outs`. `frames` device frames; anything not available is silence.
void pull(Engine &e, const Out *outs, int32_t count, int32_t frames) JM_NONBLOCKING {
    const uint64_t parked = e.parkedSeq.load(std::memory_order_acquire);
    if (parked != e.rtSeq) {
        e.readPos.store(e.writePos.load(std::memory_order_acquire), std::memory_order_release);
        e.rtBase = e.parkedStart.load(std::memory_order_relaxed);
        e.rtRatio = e.parkedRatio.load(std::memory_order_relaxed);
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
        const bool exact = e.rtRatio == 1.0;
        // Device frames left before the end of the plan.
        int64_t left = 0;
        if (end > 0) {
            left = exact ? end - e.rtBase - e.rtConsumed
                         : int64_t(std::ceil(double(end - e.rtBase) / e.rtRatio)) - e.rtConsumed;
            if (n > left) n = std::max<int64_t>(0, left);
        }
        const float g = e.gain.load(std::memory_order_relaxed);
        const int32_t ec = e.channels;
        const bool silent = e.silent.load(std::memory_order_relaxed);
        if (e.tap.load(std::memory_order_relaxed) && n > 0) {
            // What is handed over, before the volume: the sum of squares of every channel's samples.
            double sum = 0.0;
            for (int64_t i = 0; i < n; ++i) {
                const float *frame = &e.ringData[((r + uint64_t(i)) & e.mask) * uint64_t(ec)];
                for (int32_t ch = 0; ch < ec; ++ch) sum += double(frame[ch]) * double(frame[ch]);
            }
            e.tapEnergy.store(e.tapEnergy.load(std::memory_order_relaxed) + sum, std::memory_order_relaxed);
            e.tapFrames.store(e.tapFrames.load(std::memory_order_relaxed) + n, std::memory_order_relaxed);
        }
        float peaks[kMaxChannels] = {};
        for (int32_t k = 0; k < count; ++k) {
            float *o = outs[k].base;
            const int64_t stride = outs[k].stride;
            const int32_t ch = outs[k].source;
            if (ch >= 0 && ch < ec) {
                float peak = 0.0f;
                for (int64_t i = 0; i < n; ++i) {
                    const float v = e.ringData[((r + uint64_t(i)) & e.mask) * uint64_t(ec) + uint64_t(ch)] * g;
                    o[i * stride] = silent ? 0.0f : v;
                    const float a = v < 0 ? -v : v;
                    if (a > peak) peak = a;
                }
                if (peak > peaks[ch]) peaks[ch] = peak;
            } else {
                for (int64_t i = 0; i < n; ++i) o[i * stride] = 0.0f;
            }
            for (int64_t i = n; i < frames; ++i) o[i * stride] = 0.0f;
        }
        for (int32_t ch = 0; ch < ec && ch < kMaxChannels; ++ch) raise_peak(e.peaks[ch], peaks[ch]);
        e.readPos.store(r + uint64_t(n), std::memory_order_release);
        e.rtConsumed += n;
        const int64_t head = exact ? e.rtBase + e.rtConsumed : e.rtBase + int64_t(double(e.rtConsumed) * e.rtRatio);
        e.playhead.store(end > 0 && head > end ? end : head, std::memory_order_relaxed);
        if (n > 0) e.rtStarted = true;
        if (end > 0 && n >= left) {
            e.playhead.store(end, std::memory_order_relaxed);
            e.playing.store(false, std::memory_order_release);
        } else if (n < frames && e.rtStarted) {
            e.underruns.fetch_add(1, std::memory_order_relaxed);
        }
    } else {
        for (int32_t k = 0; k < count; ++k) {
            for (int64_t i = 0; i < frames; ++i) outs[k].base[i * outs[k].stride] = 0.0f;
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
void jm_engine_set_ahead(jm_engine *engine, int32_t frames) { engine->e.ahead.store(std::max<int32_t>(0, frames), std::memory_order_relaxed); }
void jm_engine_set_live_gain(jm_engine *engine, int32_t kind, int32_t index, float db, bool replaces, uint64_t plan_serial) {
    const int32_t s = LiveTrims::slot(kind, index);
    if (s < 0) return;
    LiveTrims::Slot &slot = engine->e.live.slots[s];
    slot.db.store(db, std::memory_order_relaxed);
    slot.replaces.store(replaces, std::memory_order_relaxed);
    slot.serial.store(plan_serial, std::memory_order_release);
}
int32_t jm_engine_take_applied(jm_engine *engine, int32_t *kinds, int32_t *indices, int64_t *frames, float *db, int32_t max) {
    LiveTrims &live = engine->e.live;
    int32_t n = 0;
    uint32_t t = live.tail.load(std::memory_order_relaxed);
    const uint32_t h = live.head.load(std::memory_order_acquire);
    while (t != h && n < max) {
        const LiveTrims::Applied &a = live.queue[t & (LiveTrims::kQueue - 1)];
        kinds[n] = a.slot < LiveTrims::kTracks ? 0 : a.slot < LiveTrims::kTracks + LiveTrims::kBuses ? 1 : 2;
        indices[n] = kinds[n] == 0 ? a.slot : kinds[n] == 1 ? a.slot - LiveTrims::kTracks : 0;
        frames[n] = a.frame;
        db[n] = a.db;
        ++n; ++t;
    }
    live.tail.store(t, std::memory_order_release);
    return n;
}
int64_t jm_engine_continued(const jm_engine *engine) { return engine->e.continued.load(std::memory_order_relaxed); }
int64_t jm_engine_buffered(const jm_engine *engine) {
    return int64_t(engine->e.writePos.load(std::memory_order_acquire) - engine->e.readPos.load(std::memory_order_acquire));
}
void jm_engine_set_silent(jm_engine *engine, bool silent) { engine->e.silent.store(silent, std::memory_order_relaxed); }
void jm_engine_tap(jm_engine *engine, bool on) {
    engine->e.tap.store(false, std::memory_order_relaxed);
    engine->e.tapEnergy.store(0.0, std::memory_order_relaxed);
    engine->e.tapFrames.store(0, std::memory_order_relaxed);
    engine->e.tap.store(on, std::memory_order_relaxed);
}
void jm_engine_tap_read(const jm_engine *engine, double *energy, int64_t *frames) {
    *energy = engine->e.tapEnergy.load(std::memory_order_relaxed);
    *frames = engine->e.tapFrames.load(std::memory_order_relaxed);
}
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

void jm_engine_set_output(jm_engine *engine, double device_rate, const int32_t *buffers, const int32_t *channels,
                          const int32_t *sources, int32_t count) {
    Engine &e = engine->e;
    const int32_t n = std::clamp(count, 0, kMaxSlots);
    e.slotCount.store(0, std::memory_order_release);
    for (int32_t i = 0; i < n; ++i) e.slots[i] = OutputSlot{buffers[i], channels[i], sources[i]};
    e.slotCount.store(n, std::memory_order_release);
    const double rate = device_rate > 0 ? device_rate : e.sampleRate;
    if (e.outRate.exchange(rate, std::memory_order_acq_rel) != rate) {
        // Re-park at the playhead so the worker renders at the new rate.
        e.requestFrame.store(e.playhead.load(std::memory_order_relaxed), std::memory_order_release);
        e.requestSeq.fetch_add(1, std::memory_order_acq_rel);
    }
}

double jm_engine_output_rate(const jm_engine *engine) {
    const double r = engine->e.outRate.load(std::memory_order_acquire);
    return r > 0 ? r : engine->e.sampleRate;
}

void jm_engine_pull(jm_engine *engine, float *const *outs, int32_t channels, int32_t frames) JM_NONBLOCKING {
    Out o[kMaxChannels];
    const int32_t n = std::min(channels, kMaxChannels);
    for (int32_t i = 0; i < n; ++i) o[i] = Out{outs[i], 1, i};
    pull(engine->e, o, n, frames);
}

OSStatus jm_engine_ioproc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input_data,
                          const AudioTimeStamp *input_time, AudioBufferList *output_data, const AudioTimeStamp *output_time,
                          void *client_data) JM_NONBLOCKING {
    (void)device;
    (void)now;
    (void)input_data;
    (void)input_time;
    (void)output_time;
    if (!client_data || !output_data || output_data->mNumberBuffers == 0) return noErr;
    Engine &e = static_cast<jm_engine *>(client_data)->e;
    // Silence everything first: channels nobody feeds stay quiet.
    for (UInt32 b = 0; b < output_data->mNumberBuffers; ++b) {
        float *d = static_cast<float *>(output_data->mBuffers[b].mData);
        const UInt32 count = output_data->mBuffers[b].mDataByteSize / 4;
        if (d) for (UInt32 i = 0; i < count; ++i) d[i] = 0.0f;
    }
    const AudioBuffer &first = output_data->mBuffers[0];
    if (first.mNumberChannels == 0) return noErr;
    const int32_t frames = int32_t(first.mDataByteSize / (4 * first.mNumberChannels));
    Out o[kMaxSlots];
    int32_t n = 0;
    const int32_t slots = e.slotCount.load(std::memory_order_acquire);
    for (int32_t i = 0; i < slots; ++i) {
        const OutputSlot s = e.slots[i];
        if (s.buffer < 0 || UInt32(s.buffer) >= output_data->mNumberBuffers) continue;
        const AudioBuffer &buf = output_data->mBuffers[s.buffer];
        if (!buf.mData || s.channel < 0 || UInt32(s.channel) >= buf.mNumberChannels) continue;
        if (int32_t(buf.mDataByteSize / (4 * buf.mNumberChannels)) < frames) continue;
        o[n++] = Out{static_cast<float *>(buf.mData) + s.channel, int32_t(buf.mNumberChannels), s.source};
    }
    pull(e, o, n, frames);
    return noErr;
}

OSStatus jm_engine_au_render(void *ref_con, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time_stamp,
                             UInt32 bus, UInt32 frames, AudioBufferList *io_data) JM_NONBLOCKING {
    (void)flags;
    (void)time_stamp;
    (void)bus;
    if (!io_data) return noErr;
    Out o[kMaxChannels];
    const int32_t n = int32_t(std::min<UInt32>(io_data->mNumberBuffers, UInt32(kMaxChannels)));
    for (int32_t i = 0; i < n; ++i) o[i] = Out{static_cast<float *>(io_data->mBuffers[i].mData), 1, i};
    pull(static_cast<jm_engine *>(ref_con)->e, o, n, int32_t(frames));
    return noErr;
}

} // extern "C"
