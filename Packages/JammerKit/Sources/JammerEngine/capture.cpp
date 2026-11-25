// Recording's realtime half (see jammer_engine.h, "Capture"): one lock-free single-producer single-consumer ring per
// armed track. The device thread writes, the writer thread reads; both indices only grow.
#include "jammer_engine.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <vector>

namespace {
struct Ring {
    int32_t channels = 1, first = 0;
    std::vector<float> data;               // capacity frames × channels, a power of two frames
    int64_t mask = 0;                      // capacity frames − 1
    std::atomic<int64_t> written{0}, read{0};
    std::atomic<int64_t> dropped{0};
    std::atomic<float> peak{0.0f};
};
}

struct jm_capture {
    int32_t deviceChannels = 0;
    std::vector<std::unique_ptr<Ring>> rings;
    std::atomic<int64_t> frames{0};
    std::atomic<bool> recording{false};
};

extern "C" {

jm_capture *jm_capture_create(int32_t device_channels, int32_t tracks, const int32_t *first, const int32_t *count,
                              double rate, double ring_seconds) {
    if (device_channels <= 0 || tracks <= 0 || rate <= 0 || ring_seconds <= 0) return nullptr;
    auto c = new jm_capture();
    c->deviceChannels = device_channels;
    int64_t want = (int64_t)std::ceil(rate * ring_seconds), cap = 1;
    while (cap < want) cap <<= 1;
    for (int32_t t = 0; t < tracks; t++) {
        if (count[t] < 1 || count[t] > 2 || first[t] < 0 || first[t] + count[t] > device_channels) { delete c; return nullptr; }
        auto r = std::make_unique<Ring>();
        r->channels = count[t];
        r->first = first[t];
        r->data.assign((size_t)(cap * count[t]), 0.0f);
        r->mask = cap - 1;
        c->rings.push_back(std::move(r));
    }
    return c;
}

void jm_capture_release(jm_capture *capture) { delete capture; }

void jm_capture_set_recording(jm_capture *capture, bool recording) { capture->recording.store(recording, std::memory_order_release); }

void jm_capture_push(jm_capture *c, const float *in, int32_t frames) JM_NONBLOCKING {
    const bool rec = c->recording.load(std::memory_order_acquire);
    const int32_t dc = c->deviceChannels;
    for (const auto &rp : c->rings) {
        Ring &r = *rp;
        float peak = r.peak.load(std::memory_order_relaxed);
        for (int32_t f = 0; f < frames; f++)
            for (int32_t ch = 0; ch < r.channels; ch++) peak = std::max(peak, std::fabs(in[(int64_t)f * dc + r.first + ch]));
        r.peak.store(peak, std::memory_order_relaxed);
        if (!rec) continue;
        const int64_t w = r.written.load(std::memory_order_relaxed), rd = r.read.load(std::memory_order_acquire);
        const int64_t room = (r.mask + 1) - (w - rd);
        const int32_t take = (int32_t)std::min<int64_t>(frames, room);
        for (int32_t f = 0; f < take; f++) {
            float *dst = &r.data[(size_t)(((w + f) & r.mask) * r.channels)];
            for (int32_t ch = 0; ch < r.channels; ch++) dst[ch] = in[(int64_t)f * dc + r.first + ch];
        }
        if (take < frames) r.dropped.fetch_add(frames - take, std::memory_order_relaxed);
        r.written.store(w + take, std::memory_order_release);
    }
    if (rec) c->frames.fetch_add(frames, std::memory_order_relaxed);
}

OSStatus jm_capture_ioproc(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *input, const AudioTimeStamp *,
                           AudioBufferList *, const AudioTimeStamp *, void *client) JM_NONBLOCKING {
    auto c = static_cast<jm_capture *>(client);
    if (!c || input->mNumberBuffers == 0) return noErr;
    // One interleaved stream holding every channel: pushed as it is. Several streams (one per channel or a few
    // each): gathered, a block at a time, into a buffer of fixed size on the stack.
    const AudioBuffer &b0 = input->mBuffers[0];
    if (input->mNumberBuffers == 1 && (int32_t)b0.mNumberChannels == c->deviceChannels) {
        jm_capture_push(c, static_cast<const float *>(b0.mData), (int32_t)(b0.mDataByteSize / sizeof(float) / std::max<UInt32>(1, b0.mNumberChannels)));
        return noErr;
    }
    constexpr int32_t kBlock = 256, kMax = 64;
    if (c->deviceChannels > kMax) return noErr;
    float block[kBlock * kMax];
    const int32_t frames = (int32_t)(b0.mDataByteSize / sizeof(float) / std::max<UInt32>(1, b0.mNumberChannels));
    for (int32_t at = 0; at < frames; at += kBlock) {
        const int32_t n = std::min(kBlock, frames - at);
        int32_t ch = 0;
        for (UInt32 i = 0; i < input->mNumberBuffers && ch < c->deviceChannels; i++) {
            const AudioBuffer &b = input->mBuffers[i];
            const auto *src = static_cast<const float *>(b.mData);
            for (UInt32 k = 0; k < b.mNumberChannels && ch < c->deviceChannels; k++, ch++)
                for (int32_t f = 0; f < n; f++) block[f * c->deviceChannels + ch] = src[(int64_t)(at + f) * b.mNumberChannels + k];
        }
        for (; ch < c->deviceChannels; ch++) for (int32_t f = 0; f < n; f++) block[f * c->deviceChannels + ch] = 0.0f;
        jm_capture_push(c, block, n);
    }
    return noErr;
}

int32_t jm_capture_pull(jm_capture *c, int32_t track, float *out, int32_t max_frames) {
    if (track < 0 || track >= (int32_t)c->rings.size()) return 0;
    Ring &r = *c->rings[(size_t)track];
    const int64_t rd = r.read.load(std::memory_order_relaxed), w = r.written.load(std::memory_order_acquire);
    const int32_t n = (int32_t)std::min<int64_t>(max_frames, w - rd);
    for (int32_t f = 0; f < n; f++) {
        const float *src = &r.data[(size_t)(((rd + f) & r.mask) * r.channels)];
        for (int32_t ch = 0; ch < r.channels; ch++) out[(int64_t)f * r.channels + ch] = src[ch];
    }
    r.read.store(rd + n, std::memory_order_release);
    return n;
}

int64_t jm_capture_dropped(const jm_capture *c, int32_t track) {
    return track >= 0 && track < (int32_t)c->rings.size() ? c->rings[(size_t)track]->dropped.load(std::memory_order_relaxed) : 0;
}

float jm_capture_take_peak(jm_capture *c, int32_t track) {
    return track >= 0 && track < (int32_t)c->rings.size() ? c->rings[(size_t)track]->peak.exchange(0.0f, std::memory_order_relaxed) : 0.0f;
}

int64_t jm_capture_frames(const jm_capture *c) { return c->frames.load(std::memory_order_relaxed); }

}
