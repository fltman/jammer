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
    /// A parameter set from a lane, before the block it holds for. An Audio Unit takes it itself
    /// (AudioUnitSetParameter on its global scope); a processor takes it here, if it has parameters at all.
    void (*control)(void *context, uint32_t parameter, float value) = nullptr;
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
    /// One quantum of interleaved audio through the units, in place. What comes out is as late as the
    /// units make it (`latency` frames); the mixer graph lines the paths up and hides the lateness.
    void stream(float *interleaved, const KeyFeed *keys = nullptr, size_t keyCount = 0);
    /// Sets a parameter of one unit (its place among the units) for the quantum that comes next.
    void control(size_t unit, uint32_t parameter, float value);
    /// Starts the units afresh (a seek).
    void restart();

private:
    std::mutex mutex_;
    double sampleTime_ = 0;
    std::vector<float> a_, b_, key_, zeros_;
    const KeyFeed *keys_ = nullptr;
    size_t keyCount_ = 0;
    AudioBufferList *list_ = nullptr;
    void reset();
    /// Runs the units over the quantum in `a_` (planar), leaving the result in `a_`.
    void runUnits();
};

/// A copy of a strip's signal sent to a bus: before the strip's fader and pan (`pre`), or after them.
/// Automation of a level: points on the timeline (frame, dB), a straight line in dB between them, the
/// first value before the first point and the last after the last. Part of the immutable plan. It is
/// applied in pieces of at most `kPiece` frames (fewer where the line is steep: never more than half a
/// dB of it in one piece) that lie on the timeline's own grid and end at the points, ramping linearly in
/// amplitude inside a piece: so a point lands on its own frame, the level never steps, and what a frame
/// is multiplied by depends only on where it is on the timeline, not on where a render started or how
/// it was cut into blocks.
///
/// Three kinds of value, all straight lines between points: a level in dB (a fader's automation), an
/// amplitude from 0 to 1 (an automated mute, which the compiler writes as short ramps so that it never
/// clicks), and a pan from −1 to 1 (which becomes the two channels' gains by the same law as a fixed pan).
struct Curve {
    enum Kind : int32_t { kDecibel = 0, kAmplitude = 1, kPan = 2 };
    static constexpr int64_t kPiece = 64;
    Kind kind = kDecibel;
    std::vector<int64_t> frames;
    std::vector<float> db;   // the values, whatever the kind
    bool empty() const { return frames.empty(); }
    double dbAt(int64_t t) const;
    /// `n` interleaved frames of `in`, of which the first is timeline frame `at`, times the curve, to `out`
    /// (which may be `in`).
    void apply(const float *in, float *out, int64_t at, int64_t n, int32_t channels) const;
};

/// Automation of one parameter of one plugin on a strip: the value the parameter has at each place on
/// the strip's timeline, a straight line between points. Set once a quantum (512 frames), before the
/// quantum is worked, to the line's value at the quantum's first frame as it enters the strip's plugins.
struct ParamCurve {
    int32_t unit;        // its place in the strip's chain
    uint32_t parameter;  // the unit's own number for it
    Curve curve;         // read with dbAt: a straight line in the parameter's own unit
};

struct Send {
    int32_t bus;
    float gain;
    bool pre;
    /// Automation added to the send's level (dB); empty: none.
    Curve curve;
};

struct Track {
    float gain = 1.0f;
    bool mute = false;
    /// Automation added to the fader, after the track's plugins; empty: none, and nothing is different.
    Curve curve;
    /// An automated mute (amplitude) and an automated pan, which then takes the fixed pan's place.
    Curve muteCurve, panCurve;
    bool automated() const { return !curve.empty() || !muteCurve.empty() || !panCurve.empty(); }
    /// The strip is one a fader may be ridden on while this plan plays: it is then worked as a strip of
    /// its own also in a plan that otherwise uses nothing of the mixer (where plain tracks are summed
    /// together), so that a level under a hand has a strip to be put on. The sound is the same.
    bool live = false;
    std::shared_ptr<Chain> chain;
    std::vector<ParamCurve> params;
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
    Curve curve, muteCurve, panCurve;
    bool automated() const { return !curve.empty() || !muteCurve.empty() || !panCurve.empty(); }
    float panL = 1.0f, panR = 1.0f;
    int32_t output = -1;
    std::vector<Send> sends;
    /// Plugins on the bus, after the sum and before the fader.
    std::shared_ptr<Chain> chain;
    std::vector<ParamCurve> params;
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
        /// A send's own automation (in the plan, which outlives the graph's use of it), or null.
        const Curve *curve = nullptr;
        Edge(int32_t to, float gain, bool pre, bool main) : to(to), gain(gain), pre(pre), main(main) {}
    };
    explicit Graph(const Plan &plan);
    void process(const Plan &plan, Renderer &renderer, int64_t start, int64_t n, float *out);
    /// Takes over the running state of the graph of the plan that played before this one (its delay
    /// lines, its place on the timeline, what it had made and not yet handed over), when the two graphs
    /// have the same shape. Then the next call to `process` goes on where the other stopped, with no
    /// reset: the plugins' tails and the delay compensation are untouched, so a mute, a fader or a pan
    /// that comes as a new plan doesn't cut a reverb off. False, and nothing done, when the shapes differ
    /// (a bus added, a plugin's latency changed): the new graph then starts as it always did.
    bool continueFrom(Graph &old);
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
    std::vector<int32_t> order_;
    std::vector<int64_t> nodeIn_;
    /// How late each node's signal is where it leaves the strip (after its plugins): what the graph's
    /// time is ahead of the timeline there, which is where the strip's automation is read.
    std::vector<int64_t> nodeOut_;
    int64_t masterChainLatency_ = 0;
    std::vector<float> faded_, sent_;
    /// A level under a hand, per node (and the master last): the value the block before ended on, and a
    /// two-point line from it to this block's, applied as a lane's piece is.
    std::vector<float> liveLast_;
    std::vector<bool> liveOn_;
    Curve liveRamp_;
    /// Puts a live trim on `io` for this block if the strip has one for this plan. Returns whether it did
    /// (the lane is then not applied when the trim stands in its place).
    bool trim(const Plan &plan, Renderer &renderer, int32_t kind, int32_t index, size_t node, const Curve &lane, int64_t at, int64_t q, const float *in, float *out, bool &replaced);
    struct KeyBuffer {
        int32_t unit;
        std::vector<float> data;
    };
    std::vector<std::vector<KeyBuffer>> keyBuffers_;
    std::vector<std::vector<Chain::KeyFeed>> feeds_;
    /// A plan that uses nothing of the mixer (no bus, no pan, no key): the tracks without plugins are
    /// summed clip by clip with the track's gain folded in, before the tracks with plugins, as the
    /// renderer has always done it, so that such a project gives the bits it always gave. That sum then
    /// waits like any other path for the longest one.
    bool plain_ = false;
    /// Some plugin's parameter is automated in the plan (see reset).
    bool params_ = false;
    std::vector<float> direct_, directLine_;
    size_t directAt_ = 0;
    bool sameShape(const Graph &o) const;
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
    std::vector<ParamCurve> masterParams;
    /// Automation of the master's level: after its plugins, with its gain, before the limiter.
    Curve masterCurve;
    std::vector<Clip> clips; // sorted by start once finalized
    int64_t length = 0;
    bool finalized = false;
    /// Which plan this is among all that have been made: what a live trim is tied to.
    uint64_t serial = 0;
};

bool continuePlan(Plan &next, Plan &prev);

/// A level under a hand: for a strip, a value in dB that the render thread puts on in the lane's place
/// (or on top of the lane), block by block, while a fader is held and the sound plays. Written by the
/// main thread, read by the render thread once a block; and, the other way, what the render thread put
/// on and at which frame of the strip's timeline, for the lane that is written from it afterwards.
/// A trim belongs to one plan (its serial): the plan that comes after it, with the fader or the lane
/// that the hand left, is never trimmed by it, so the level goes from one to the other between two
/// blocks without a step.
struct LiveTrims {
    static constexpr int32_t kTracks = 256, kBuses = 64, kSlots = kTracks + kBuses + 1;
    static int32_t slot(int32_t kind, int32_t index) {   // kind 0 track, 1 bus, 2 master; -1: no such slot
        if (kind == 0) return index >= 0 && index < kTracks ? index : -1;
        if (kind == 1) return index >= 0 && index < kBuses ? kTracks + index : -1;
        return kind == 2 ? kTracks + kBuses : -1;
    }
    struct Slot {
        std::atomic<uint64_t> serial{0};   // the plan it is for; 0: none
        std::atomic<float> db{0.0f};
        std::atomic<bool> replaces{true};  // in the lane's place (written afterwards), or on top of it (only heard)
    };
    Slot slots[kSlots];
    /// What was put on: one entry a block and strip, from the render thread to the main thread.
    struct Applied { int32_t slot; int64_t frame; float db; };
    static constexpr uint32_t kQueue = 8192;   // a power of two; about 40 s of one strip at 256 frames a block
    Applied queue[kQueue];
    std::atomic<uint32_t> head{0}, tail{0};
    void push(const Applied &a) {
        const uint32_t h = head.load(std::memory_order_relaxed);
        if (h - tail.load(std::memory_order_acquire) >= kQueue) return;   // full: the entry is dropped (the main thread takes them four times a second)
        queue[h & (kQueue - 1)] = a;
        head.store(h + 1, std::memory_order_release);
    }
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

public:
    /// The engine's live trims, for the renderer that plays; null for every other render (an export, a
    /// measurement), which is never trimmed.
    LiveTrims *live = nullptr;

private:
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
