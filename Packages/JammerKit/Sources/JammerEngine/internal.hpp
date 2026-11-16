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
    /// A unit with a sidechain input gets its key here, laid out like `feed`, in step with it; silence
    /// when nothing is keyed to it. A processor takes it through `processKeyed`, an Audio Unit pulls
    /// it on its second input (`keyBus`).
    const float *key = nullptr;
    bool keyBus = false;
    bool (*processKeyed)(void *context, const float *in, const float *key, float *out, int32_t channels, int32_t frames) = nullptr;
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
        /// The key on its way to this unit: as late as the units before it make the audio (planar ring).
        std::vector<float> keyHeld;
        int64_t keyAt = 0;
    };
    /// A key for one unit of the chain (its place among the units), one quantum, interleaved, in step
    /// with the audio that goes into the chain.
    struct KeyFeed {
        int32_t unit;
        const float *interleaved;
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
    /// For a chain on a bus: one quantum of interleaved audio through the units, in place. What comes
    /// out is as late as the units make it (`latency` frames); the mixer graph lines the paths up.
    void stream(float *interleaved, const KeyFeed *keys = nullptr, size_t keyCount = 0);
    /// Starts the units afresh (a seek).
    void restart();

private:
    std::mutex mutex_;
    bool primed_ = false;
    int64_t readPos_ = 0;   // timeline frame of the next output frame
    int64_t inCursor_ = 0;  // timeline frame of the next input frame
    int64_t discard_ = 0;   // output frames still to drop after a reset
    double sampleTime_ = 0;
    std::vector<float> fifo_;  // interleaved, processed, from readPos_
    size_t fifoHead_ = 0;      // frames consumed from fifo_
    std::vector<float> interleaved_, a_, b_, key_, zeros_;
    const KeyFeed *keys_ = nullptr;
    size_t keyCount_ = 0;
    AudioBufferList *list_ = nullptr;
    void reset(int64_t start);
    void produce(const Plan &plan, int32_t track, Renderer &renderer);
    /// Runs the units over the quantum in `a_` (planar), leaving the result in `a_`.
    void runUnits();
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
    /// Plugins on the bus, after the sum and before the fader.
    std::shared_ptr<Chain> chain;
};

/// The mixer with plugins on buses. A plugin on a bus makes what leaves the bus late by its latency,
/// so wherever signals meet (a bus's input, the output) every path is delayed to the longest one, and
/// the whole mix comes out late by the longest path through it: `total`. The graph runs that far ahead
/// of what it is asked for, so the caller gets the mix on the sample. It keeps its place between calls
/// (the units, the delay lines) and starts again, with a run-in, when asked for another place.
class Graph {
public:
    struct Edge {
        int32_t to;        // a bus, or -1 for the output
        float gain;        // the send's or the strip's gain
        bool pre;          // before the strip's fader and pan
        bool main;         // the strip's own way out (its fader and pan apply) rather than a send
        int64_t delay = 0; // frames added so this path lines up with the longest into `to`
        std::vector<float> line;
        size_t at = 0;
        /// A key: the strip's signal after its fader, to unit `keyUnit` of node `keyNode`'s chain. -1: not a key.
        int32_t keyNode = -1, keyUnit = -1;
        Edge(int32_t to, float gain, bool pre, bool main) : to(to), gain(gain), pre(pre), main(main) {}
    };
    explicit Graph(const Plan &plan);
    void process(const Plan &plan, Renderer &renderer, int64_t start, int64_t n, float *out);
    int64_t total = 0;                      // the longest path through the buses, in frames
    int64_t masterLatency = 0;              // what the master's plugins and its limiter add after that
    std::vector<int64_t> busLatency;        // each bus's own chain
    std::vector<int64_t> trackDelay;        // added to each track's own way out
    std::vector<int64_t> busDelay;          // added to each bus's own way out

private:
    static constexpr int64_t kQuantum = Chain::kQuantum;
    std::mutex mutex_;
    int32_t channels_;
    int64_t preroll_ = 0;
    std::vector<std::vector<Edge>> trackEdges_, busEdges_;
    bool primed_ = false;
    int64_t readPos_ = 0, cursor_ = 0, discard_ = 0;
    std::vector<float> fifo_;
    size_t fifoHead_ = 0;
    std::vector<float> strip_, mix_;
    std::vector<std::vector<float>> bus_;
    /// With a key in the plan every strip is a node (tracks 0…, then buses), worked through in an order
    /// in which a key's source comes before the strip that listens to it. The tracks' chains then run as
    /// streams like the buses', and `nodeIn_` is how late each node's input is.
    bool keyed_ = false;
    std::vector<int32_t> order_;
    std::vector<int64_t> nodeIn_;
    struct KeyBuffer {
        int32_t unit;
        std::vector<float> data;
    };
    std::vector<std::vector<KeyBuffer>> keyBuffers_;
    std::vector<std::vector<Chain::KeyFeed>> feeds_;
    void reset(const Plan &plan, int64_t start);
    void produce(const Plan &plan, Renderer &renderer);
    void send(Edge &e, const float *in, float gainL, float gainR, int64_t n);
};

struct Plan {
    int32_t channels;
    double sampleRate;
    std::vector<std::shared_ptr<Source>> sources;
    std::vector<Track> tracks;
    std::vector<Bus> buses;
    /// Buses in the order they are summed: every bus before the one it feeds. Made by finalize.
    std::vector<int32_t> busOrder;
    /// Sidechain keys: the signal of one strip, after its fader, to one unit of another strip's chain.
    struct Key {
        bool toBus;
        int32_t to;
        int32_t unit;
        bool fromBus;
        int32_t from;
    };
    std::vector<Key> keys;
    /// With keys: every strip (a track is its index, a bus is the number of tracks plus its index),
    /// each after every strip it listens to or is fed by.
    std::vector<int32_t> nodeOrder;
    /// True when anything is routed to a bus or panned. False is the path every plan took before
    /// there was a mixer, and still takes: the same code, the same bits.
    bool routed = false;
    /// Made by finalize when a bus has plugins or the master does anything; otherwise the mixer needs
    /// no state and has none.
    std::shared_ptr<Graph> graph;
    /// The master: the sum of everything → its plugins → its gain → its limiter, last of all.
    float masterGain = 1.0f;
    std::shared_ptr<Chain> masterChain, masterLimiter;
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
    friend class Graph;
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
