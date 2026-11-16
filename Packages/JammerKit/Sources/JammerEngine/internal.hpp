// Shared C++ types behind the C API. Not part of the public header.

#pragma once

#include "jammer_engine.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace jm {

struct Source {
    int fd = -1;
    int64_t dataOffset = 0;
    int64_t frames = 0;
    int32_t channels = 1;
    jm_sample_format format = JM_PCM_F32;
    bool bigEndian = false;
    std::vector<float> memory; // non-empty for in-memory sources

    ~Source();
    /// Thread-safe (pread); allocates scratch, so never on the audio thread.
    int64_t read(int64_t frame, int64_t count, float *out) const;
};

struct Clip {
    int32_t track;
    int32_t source;
    int64_t sourceStart;
    int64_t start; // timeline
    int64_t length;
    float gain;
    int64_t fadeIn;
    int64_t fadeOut;
    jm_fade_shape shape;
    int64_t end() const { return start + length; }
};

struct Plan;
class Renderer;

/// One effect in a chain: an Audio Unit and the input its render callback hands it, or a
/// processor the caller supplies (a plugin that lives in a helper process).
struct Unit {
    AudioUnit unit = nullptr;
    /// Set instead of `unit`: planar in and out, `channels` × `frames` floats each (channel c at
    /// c × frames). False when the block wasn't processed. Called from the render worker or an
    /// offline render, never the device thread, and may block.
    bool (*process)(void *context, const float *in, float *out, int32_t channels, int32_t frames) = nullptr;
    void (*reset)(void *context) = nullptr;
    int32_t channels = 1;
    void *context = nullptr;
    void (*release)(void *) = nullptr;
    /// Set by the chain right before AudioUnitRender: non-interleaved input.
    const float *feed = nullptr;
    int64_t feedFrames = 0;
    ~Unit();
};

/// A track's insert chain and its stream state. Used by one render at a time (locked).
struct Chain {
    static constexpr int64_t kQuantum = 512;
    struct Entry {
        std::shared_ptr<Unit> unit;
        int64_t latency;
        /// The last `latency` frames that went in (planar ring, per channel). When the unit fails,
        /// its input comes out through this, so the track stays in time with the others: the
        /// chain has already been compensated for the unit's latency.
        std::vector<float> held;
        int64_t heldAt = 0;
    };

    int32_t channels;
    int64_t preroll;
    std::vector<Entry> units;
    int64_t latency = 0;
    std::atomic<OSStatus> status{0};

    Chain(int32_t channels, int64_t preroll);
    ~Chain();
    /// Writes `n` processed frames of `track` from `start` to `out` (interleaved, overwritten).
    void process(const Plan &plan, int32_t track, Renderer &renderer, int64_t start, int64_t n, float *out);

private:
    std::mutex mutex_;
    bool primed_ = false;
    int64_t readPos_ = 0;   // timeline frame of the next output frame
    int64_t inCursor_ = 0;  // timeline frame of the next input frame
    int64_t discard_ = 0;   // output frames still to drop after a reset
    double sampleTime_ = 0;
    std::vector<float> fifo_;  // interleaved, processed, from readPos_
    size_t fifoHead_ = 0;      // frames consumed from fifo_
    std::vector<float> interleaved_, a_, b_;
    AudioBufferList *list_ = nullptr;
    void reset(int64_t start);
    void produce(const Plan &plan, int32_t track, Renderer &renderer);
};

/// A copy of a strip's signal sent to a bus: before the strip's fader and pan (`pre`), or after them.
struct Send {
    int32_t bus;
    float gain;
    bool pre;
};

struct Track {
    float gain = 1.0f;
    bool mute = false;
    std::shared_ptr<Chain> chain;
    std::vector<Send> sends;
    /// Where the track goes: a bus (its index), or -1 for the output. With pan: the gain of the left
    /// and of the right channel (1 and 1 at the centre).
    int32_t bus = -1;
    float panL = 1.0f, panR = 1.0f;
};

/// A bus: the sum of what is routed to it, with a gain and pan of its own, on to another bus or the output.
struct Bus {
    float gain = 1.0f;
    bool mute = false;
    float panL = 1.0f, panR = 1.0f;
    int32_t output = -1;
    std::vector<Send> sends;
};

struct Plan {
    int32_t channels;
    double sampleRate;
    std::vector<std::shared_ptr<Source>> sources;
    std::vector<Track> tracks;
    std::vector<Bus> buses;
    /// Buses in the order they are summed: every bus before the one it feeds. Made by finalize.
    std::vector<int32_t> busOrder;
    /// True when anything is routed to a bus or panned. False is the path every plan took before
    /// there was a mixer, and still takes: the same code, the same bits.
    bool routed = false;
    std::vector<Clip> clips; // sorted by start once finalized
    int64_t length = 0;
    bool finalized = false;
};

/// Renders a plan into interleaved float. Owns its scratch, so reuse one per thread.
class Renderer {
public:
    explicit Renderer(int32_t channels) : channels_(channels) {}
    void render(const Plan &plan, int64_t start, int64_t frames, float *out);
    /// One track's clips with clip gains and fades only (no track gain or mute), any range.
    void renderTrack(const Plan &plan, int32_t track, int64_t start, int64_t frames, float *out);

private:
    int32_t channels_;
    std::vector<float> scratch_;
    std::vector<float> track_;
    std::vector<std::vector<float>> bus_;
    void renderRouted(const Plan &plan, int64_t start, int64_t frames, float *out);
    void mixClip(const Plan &plan, const Clip &c, float trackGain, int64_t start, int64_t frames, float *out);
};

} // namespace jm

struct jm_source {
    std::shared_ptr<jm::Source> ptr;
};

struct jm_plan {
    std::shared_ptr<jm::Plan> ptr;
};

struct jm_unit {
    std::shared_ptr<jm::Unit> ptr;
};

struct jm_chain {
    std::shared_ptr<jm::Chain> ptr;
};
