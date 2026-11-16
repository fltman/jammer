// Insert chains: Audio Units on a track, run in the render worker or an offline render.

#include "internal.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace jm {

namespace {

/// The units' input: hands over what the chain set in `feed` (non-interleaved).
OSStatus unit_input(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                    AudioBufferList *io) JM_NONBLOCKING {
    auto *u = static_cast<Unit *>(ref);
    if (!u->feed || int64_t(frames) > u->feedFrames) return kAudioUnitErr_TooManyFramesToProcess;
    for (UInt32 b = 0; b < io->mNumberBuffers; ++b) {
        const float *src = u->feed + int64_t(std::min<UInt32>(b, UInt32(u->channels - 1))) * u->feedFrames;
        if (io->mBuffers[b].mData == nullptr) {
            io->mBuffers[b].mData = const_cast<float *>(src);
        } else {
            std::memcpy(io->mBuffers[b].mData, src, size_t(frames) * sizeof(float));
        }
        io->mBuffers[b].mDataByteSize = frames * sizeof(float);
    }
    return noErr;
}

/// The units' second input: the key.
OSStatus unit_key_input(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames,
                        AudioBufferList *io) JM_NONBLOCKING {
    auto *u = static_cast<Unit *>(ref);
    if (!u->key || int64_t(frames) > u->feedFrames) return kAudioUnitErr_TooManyFramesToProcess;
    for (UInt32 b = 0; b < io->mNumberBuffers; ++b) {
        const float *src = u->key + int64_t(std::min<UInt32>(b, UInt32(u->channels - 1))) * u->feedFrames;
        if (io->mBuffers[b].mData == nullptr) {
            io->mBuffers[b].mData = const_cast<float *>(src);
        } else {
            std::memcpy(io->mBuffers[b].mData, src, size_t(frames) * sizeof(float));
        }
        io->mBuffers[b].mDataByteSize = frames * sizeof(float);
    }
    return noErr;
}

} // namespace

Unit::~Unit() {
    if (unit) {
        AURenderCallbackStruct none{nullptr, nullptr};
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &none, sizeof(none));
        if (keyBus) AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 1, &none, sizeof(none));
    }
    if (release) release(context);
}

Chain::Chain(int32_t channels, int64_t preroll) : channels(channels), preroll(std::max<int64_t>(0, preroll)) {
    interleaved_.assign(size_t(kQuantum * channels), 0.0f);
    a_.assign(size_t(kQuantum * channels), 0.0f);
    b_.assign(size_t(kQuantum * channels), 0.0f);
    key_.assign(size_t(kQuantum * channels), 0.0f);
    zeros_.assign(size_t(kQuantum * channels), 0.0f);
    list_ = static_cast<AudioBufferList *>(
        std::calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * size_t(channels)));
    list_->mNumberBuffers = UInt32(channels);
}

Chain::~Chain() { std::free(list_); }

void Chain::reset(int64_t start) {
    for (auto &e : units) {
        if (e.unit->unit) AudioUnitReset(e.unit->unit, kAudioUnitScope_Global, 0);
        else if (e.unit->reset) e.unit->reset(e.unit->context);
        std::fill(e.held.begin(), e.held.end(), 0.0f);
        e.heldAt = 0;
        std::fill(e.keyHeld.begin(), e.keyHeld.end(), 0.0f);
        e.keyAt = 0;
    }
    sampleTime_ = 0;
    inCursor_ = start - preroll;
    discard_ = preroll + latency;
    readPos_ = start;
    fifo_.clear();
    fifoHead_ = 0;
    primed_ = true;
}

void Chain::produce(const Plan &plan, int32_t track, Renderer &renderer) {
    const int64_t q = kQuantum;
    renderer.renderTrack(plan, track, inCursor_, q, interleaved_.data());
    for (int64_t i = 0; i < q; ++i)
        for (int32_t c = 0; c < channels; ++c) a_[size_t(c * q + i)] = interleaved_[size_t(i * channels + c)];
    runUnits();
    inCursor_ += q;
    const int64_t skip = std::min(discard_, q);
    discard_ -= skip;
    for (int64_t i = skip; i < q; ++i)
        for (int32_t c = 0; c < channels; ++c) fifo_.push_back(a_[size_t(c * q + i)]);
}

void Chain::stream(float *interleaved, const KeyFeed *keys, size_t keyCount) {
    std::lock_guard<std::mutex> lock(mutex_);
    const int64_t q = kQuantum;
    for (int64_t i = 0; i < q; ++i)
        for (int32_t c = 0; c < channels; ++c) a_[size_t(c * q + i)] = interleaved[size_t(i * channels + c)];
    keys_ = keys;
    keyCount_ = keyCount;
    runUnits();
    keys_ = nullptr;
    keyCount_ = 0;
    for (int64_t i = 0; i < q; ++i)
        for (int32_t c = 0; c < channels; ++c) interleaved[size_t(i * channels + c)] = a_[size_t(c * q + i)];
}

void Chain::restart() {
    std::lock_guard<std::mutex> lock(mutex_);
    reset(0);
}

void Chain::runUnits() {
    const int64_t q = kQuantum;
    AudioTimeStamp ts{};
    ts.mSampleTime = sampleTime_;
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    int64_t before = 0; // how late the audio is when it reaches this unit: the units before it
    for (size_t k = 0; k < units.size(); ++k) {
        Entry &e = units[k];
        Unit &u = *e.unit;
        // The key for this unit, if it has one: made as late as the audio is here, so the two stay in step.
        u.key = zeros_.data();
        if (u.processKeyed || u.keyBus) {
            for (size_t f = 0; f < keyCount_; ++f) {
                if (keys_[f].unit != int32_t(k) || !keys_[f].interleaved) continue;
                const float *in = keys_[f].interleaved;
                if (before == 0) {
                    for (int64_t i = 0; i < q; ++i)
                        for (int32_t c = 0; c < channels; ++c) key_[size_t(c * q + i)] = in[size_t(i * channels + c)];
                } else {
                    if (int64_t(e.keyHeld.size()) != before * channels) { e.keyHeld.assign(size_t(before * channels), 0.0f); e.keyAt = 0; }
                    for (int64_t i = 0; i < q; ++i) {
                        for (int32_t c = 0; c < channels; ++c) {
                            float &slot = e.keyHeld[size_t(c * before + e.keyAt)];
                            key_[size_t(c * q + i)] = slot;
                            slot = in[size_t(i * channels + c)];
                        }
                        e.keyAt = (e.keyAt + 1) % before;
                    }
                }
                u.key = key_.data();
                break;
            }
        }
        before += e.latency;
        bool ok;
        if (u.processKeyed) {
            ok = u.processKeyed(u.context, a_.data(), u.key, b_.data(), channels, int32_t(q));
            if (!ok) status.store(-1, std::memory_order_relaxed);
        } else if (u.process) {
            ok = u.process(u.context, a_.data(), b_.data(), channels, int32_t(q));
            if (!ok) status.store(-1, std::memory_order_relaxed);
        } else {
            u.feed = a_.data();
            u.feedFrames = q;
            for (int32_t c = 0; c < channels; ++c) {
                list_->mBuffers[c].mNumberChannels = 1;
                list_->mBuffers[c].mDataByteSize = UInt32(q * sizeof(float));
                list_->mBuffers[c].mData = b_.data() + c * q;
            }
            AudioUnitRenderActionFlags flags = 0;
            const OSStatus err = AudioUnitRender(u.unit, &flags, &ts, 0, UInt32(q), list_);
            u.feed = nullptr;
            ok = err == noErr;
            if (!ok) status.store(err, std::memory_order_relaxed);
            if (ok) {
                for (int32_t c = 0; c < channels; ++c) {
                    const float *got = static_cast<const float *>(list_->mBuffers[c].mData);
                    if (got && got != b_.data() + c * q) std::memcpy(b_.data() + c * q, got, size_t(q) * sizeof(float));
                }
            }
        }
        // Remember what went in, and when the unit failed let that through, as late as the unit
        // would have been: the chain is compensated for its latency whether it works or not.
        if (e.latency > 0) {
            for (int64_t i = 0; i < q; ++i) {
                for (int32_t c = 0; c < channels; ++c) {
                    float &slot = e.held[size_t(c * e.latency + e.heldAt)];
                    const float in = a_[size_t(c * q + i)];
                    if (!ok) b_[size_t(c * q + i)] = slot;
                    slot = in;
                }
                e.heldAt = (e.heldAt + 1) % e.latency;
            }
            std::swap(a_, b_);
        } else if (ok) {
            std::swap(a_, b_);
        }
    }
    sampleTime_ += double(q);
}

void Chain::process(const Plan &plan, int32_t track, Renderer &renderer, int64_t start, int64_t n, float *out) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!primed_ || start != readPos_) reset(start);
    while (int64_t(fifo_.size() / size_t(channels) - fifoHead_) < n) produce(plan, track, renderer);
    std::memcpy(out, fifo_.data() + fifoHead_ * size_t(channels), size_t(n * channels) * sizeof(float));
    fifoHead_ += size_t(n);
    readPos_ += n;
    if (fifoHead_ * 2 > fifo_.size() / size_t(channels)) {
        fifo_.erase(fifo_.begin(), fifo_.begin() + std::ptrdiff_t(fifoHead_ * size_t(channels)));
        fifoHead_ = 0;
    }
}

} // namespace jm

using namespace jm;

extern "C" {

jm_unit *jm_unit_create(AudioUnit unit, int32_t channels, void *context, void (*release)(void *)) {
    auto u = std::make_shared<Unit>();
    u->unit = unit;
    u->channels = std::max(1, channels);
    u->context = context;
    u->release = release;
    AURenderCallbackStruct cb{unit_input, u.get()};
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    return new jm_unit{std::move(u)};
}

jm_unit *jm_unit_create_keyed_processor(int32_t channels, void *context,
                                        bool (*process)(void *, const float *, const float *, float *, int32_t, int32_t),
                                        void (*reset)(void *), void (*release)(void *)) {
    auto u = std::make_shared<Unit>();
    u->channels = std::max(1, channels);
    u->context = context;
    u->processKeyed = process;
    u->reset = reset;
    u->release = release;
    return new jm_unit{std::move(u)};
}

bool jm_unit_enable_key_input(jm_unit *unit) {
    Unit &u = *unit->ptr;
    if (!u.unit) return u.processKeyed != nullptr;
    AURenderCallbackStruct cb{unit_key_input, &u};
    if (AudioUnitSetProperty(u.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 1, &cb, sizeof(cb)) != noErr) return false;
    u.keyBus = true;
    return true;
}

jm_unit *jm_unit_create_processor(int32_t channels, void *context, bool (*process)(void *, const float *, float *, int32_t, int32_t),
                                  void (*reset)(void *), void (*release)(void *)) {
    auto u = std::make_shared<Unit>();
    u->channels = std::max(1, channels);
    u->context = context;
    u->process = process;
    u->reset = reset;
    u->release = release;
    return new jm_unit{std::move(u)};
}

void jm_unit_release(jm_unit *unit) { delete unit; }

jm_chain *jm_chain_create(int32_t channels, int64_t preroll) {
    return new jm_chain{std::make_shared<Chain>(std::max(1, channels), preroll)};
}

void jm_chain_add(jm_chain *chain, jm_unit *unit, int64_t latency) {
    const int64_t l = std::max<int64_t>(0, latency);
    Chain::Entry e{unit->ptr, l, {}, 0, {}, 0};
    e.held.assign(size_t(l * chain->ptr->channels), 0.0f);
    chain->ptr->units.push_back(std::move(e));
    chain->ptr->latency += l;
}

void jm_chain_release(jm_chain *chain) { delete chain; }
int64_t jm_chain_latency(const jm_chain *chain) { return chain->ptr->latency; }
OSStatus jm_chain_status(const jm_chain *chain) { return chain->ptr->status.load(std::memory_order_relaxed); }

} // extern "C"
