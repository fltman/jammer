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

} // namespace

Unit::~Unit() {
    if (unit) {
        AURenderCallbackStruct none{nullptr, nullptr};
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &none, sizeof(none));
    }
    if (release) release(context);
}

Chain::Chain(int32_t channels, int64_t preroll) : channels(channels), preroll(std::max<int64_t>(0, preroll)) {
    interleaved_.assign(size_t(kQuantum * channels), 0.0f);
    a_.assign(size_t(kQuantum * channels), 0.0f);
    b_.assign(size_t(kQuantum * channels), 0.0f);
    list_ = static_cast<AudioBufferList *>(
        std::calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * size_t(channels)));
    list_->mNumberBuffers = UInt32(channels);
}

Chain::~Chain() { std::free(list_); }

void Chain::reset(int64_t start) {
    for (auto &e : units) AudioUnitReset(e.unit->unit, kAudioUnitScope_Global, 0);
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
    AudioTimeStamp ts{};
    ts.mSampleTime = sampleTime_;
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    for (auto &e : units) {
        Unit &u = *e.unit;
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
        if (err != noErr) {
            status.store(err, std::memory_order_relaxed);
            continue; // pass the input through
        }
        for (int32_t c = 0; c < channels; ++c) {
            const float *got = static_cast<const float *>(list_->mBuffers[c].mData);
            if (got && got != b_.data() + c * q) std::memcpy(b_.data() + c * q, got, size_t(q) * sizeof(float));
        }
        std::swap(a_, b_);
    }
    sampleTime_ += double(q);
    inCursor_ += q;
    const int64_t skip = std::min(discard_, q);
    discard_ -= skip;
    for (int64_t i = skip; i < q; ++i)
        for (int32_t c = 0; c < channels; ++c) fifo_.push_back(a_[size_t(c * q + i)]);
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

void jm_unit_release(jm_unit *unit) { delete unit; }

jm_chain *jm_chain_create(int32_t channels, int64_t preroll) {
    return new jm_chain{std::make_shared<Chain>(std::max(1, channels), preroll)};
}

void jm_chain_add(jm_chain *chain, jm_unit *unit, int64_t latency) {
    chain->ptr->units.push_back(Chain::Entry{unit->ptr, std::max<int64_t>(0, latency)});
    chain->ptr->latency += std::max<int64_t>(0, latency);
}

void jm_chain_release(jm_chain *chain) { delete chain; }
int64_t jm_chain_latency(const jm_chain *chain) { return chain->ptr->latency; }
OSStatus jm_chain_status(const jm_chain *chain) { return chain->ptr->status.load(std::memory_order_relaxed); }

} // extern "C"
