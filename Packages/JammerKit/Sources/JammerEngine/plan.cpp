// Plans and the deterministic renderer shared by playback and offline export.

#include "internal.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace jm {

namespace {

/// Gain of the fades at `p` frames into the clip. 1 outside the fades.
inline float fade_gain(const Clip &c, int64_t p) {
    float g = 1.0f;
    if (c.fadeIn > 0 && p < c.fadeIn) {
        float t = float(double(p) / double(c.fadeIn));
        g *= c.shape == JM_FADE_EQUAL_POWER ? std::sin(t * 1.57079632679f) : t;
    }
    if (c.fadeOut > 0 && p >= c.length - c.fadeOut) {
        float t = float(double(c.length - p) / double(c.fadeOut));
        g *= c.shape == JM_FADE_EQUAL_POWER ? std::sin(t * 1.57079632679f) : t;
    }
    return g;
}

} // namespace

void Renderer::mixClip(const Plan &plan, const Clip &c, float trackGain, int64_t start, int64_t frames, float *out) {
    const int64_t end = start + frames;
    const Source &src = *plan.sources[size_t(c.source)];
    const int64_t a = std::max(start, c.start);
    const int64_t b = std::min(end, c.end());
    const int64_t n = b - a;
    const int32_t sc = src.channels;
    scratch_.resize(size_t(n * sc));
    const int64_t got = src.read(c.sourceStart + (a - c.start), n, scratch_.data());
    const float base = c.gain * trackGain;
    const bool fades = c.fadeIn > 0 || c.fadeOut > 0;
    for (int64_t i = 0; i < got; ++i) {
        const float g = fades ? base * fade_gain(c, a - c.start + i) : base;
        float *o = out + (a - start + i) * channels_;
        const float *s = scratch_.data() + i * sc;
        for (int32_t ch = 0; ch < channels_; ++ch) {
            if (sc == 1) o[ch] += s[0] * g;
            else if (ch < sc) o[ch] += s[ch] * g;
        }
    }
}

/// Every plan is rendered by its mixer graph (see Graph): finalize always makes one. (Until 2026-11-16
/// there were three ways: a plain loop for plans that used nothing of the mixer, another for buses and
/// pan, and the graph for plugins on buses and keys. The graph gives the samples the other two gave;
/// see docs/MIXER.md and the tag before-graph-only.)
void Renderer::render(const Plan &plan, int64_t start, int64_t frames, float *out) {
    if (plan.graph) { plan.graph->process(plan, *this, start, frames, out); return; }
    std::memset(out, 0, size_t(frames * channels_) * sizeof(float)); // a plan that was never finalized
}

void Renderer::renderTrack(const Plan &plan, int32_t track, int64_t start, int64_t frames, float *out) {
    std::memset(out, 0, size_t(frames * channels_) * sizeof(float));
    const int64_t end = start + frames;
    for (const Clip &c : plan.clips) {
        if (c.start >= end) break;
        if (c.track != track || c.end() <= start) continue;
        mixClip(plan, c, 1.0f, start, frames, out);
    }
}

} // namespace jm

using namespace jm;

extern "C" {

jm_plan *jm_plan_create(int32_t channels, double sample_rate) {
    auto p = std::make_shared<Plan>();
    p->channels = std::max(1, channels);
    p->sampleRate = sample_rate;
    return new jm_plan{std::move(p)};
}

int32_t jm_plan_add_source(jm_plan *plan, jm_source *source) {
    plan->ptr->sources.push_back(source->ptr);
    return int32_t(plan->ptr->sources.size() - 1);
}

int32_t jm_plan_add_track(jm_plan *plan, float gain, bool mute) {
    Track t;
    t.gain = gain;
    t.mute = mute;
    plan->ptr->tracks.push_back(std::move(t));
    return int32_t(plan->ptr->tracks.size() - 1);
}

void jm_plan_add_clip(jm_plan *plan, int32_t track, int32_t source, int64_t source_start, int64_t timeline_start,
                      int64_t length, float gain, int64_t fade_in, int64_t fade_out, jm_fade_shape shape) {
    Plan &p = *plan->ptr;
    if (p.finalized || length <= 0) return;
    if (track < 0 || size_t(track) >= p.tracks.size() || source < 0 || size_t(source) >= p.sources.size()) return;
    fade_in = std::clamp<int64_t>(fade_in, 0, length);
    fade_out = std::clamp<int64_t>(fade_out, 0, length);
    p.clips.push_back(Clip{track, source, std::max<int64_t>(0, source_start), timeline_start, length, gain,
                           fade_in, fade_out, shape});
}

int32_t jm_plan_add_bus(jm_plan *plan, float gain, bool mute, float pan_l, float pan_r) {
    Plan &p = *plan->ptr;
    if (p.finalized) return -1;
    Bus b;
    b.gain = gain;
    b.mute = mute;
    b.panL = pan_l;
    b.panR = pan_r;
    p.buses.push_back(std::move(b));
    p.routed = true;
    return int32_t(p.buses.size() - 1);
}

void jm_plan_set_bus_output(jm_plan *plan, int32_t bus, int32_t output) {
    Plan &p = *plan->ptr;
    if (p.finalized || bus < 0 || size_t(bus) >= p.buses.size()) return;
    p.buses[size_t(bus)].output = output >= 0 && size_t(output) < p.buses.size() && output != bus ? output : -1;
}

void jm_plan_set_track_route(jm_plan *plan, int32_t track, int32_t bus, float pan_l, float pan_r) {
    Plan &p = *plan->ptr;
    if (p.finalized || track < 0 || size_t(track) >= p.tracks.size()) return;
    Track &t = p.tracks[size_t(track)];
    t.bus = bus >= 0 && size_t(bus) < p.buses.size() ? bus : -1;
    t.panL = pan_l;
    t.panR = pan_r;
    p.routed = true;
}

void jm_plan_add_track_send(jm_plan *plan, int32_t track, int32_t bus, float gain, bool pre) {
    Plan &p = *plan->ptr;
    if (p.finalized || track < 0 || size_t(track) >= p.tracks.size() || bus < 0 || size_t(bus) >= p.buses.size()) return;
    p.tracks[size_t(track)].sends.push_back(Send{bus, gain, pre, Curve{}});
    p.routed = true;
}

void jm_plan_add_bus_send(jm_plan *plan, int32_t bus, int32_t to, float gain, bool pre) {
    Plan &p = *plan->ptr;
    if (p.finalized || bus < 0 || size_t(bus) >= p.buses.size() || to < 0 || size_t(to) >= p.buses.size() || to == bus) return;
    p.buses[size_t(bus)].sends.push_back(Send{to, gain, pre, Curve{}});
}

void jm_plan_set_bus_chain(jm_plan *plan, int32_t bus, jm_chain *chain) {
    Plan &p = *plan->ptr;
    if (p.finalized || bus < 0 || size_t(bus) >= p.buses.size()) return;
    p.buses[size_t(bus)].chain = chain->ptr;
}

void jm_plan_add_key(jm_plan *plan, bool to_bus, int32_t to, int32_t unit, bool from_bus, int32_t from) {
    Plan &p = *plan->ptr;
    if (p.finalized) return;
    p.keys.push_back(Plan::Key{to_bus, to, unit, from_bus, from});
}

int32_t jm_plan_key_count(const jm_plan *plan) { return int32_t(plan->ptr->keys.size()); }



void jm_plan_set_master(jm_plan *plan, float gain, jm_chain *chain, jm_chain *limiter) {
    Plan &p = *plan->ptr;
    if (p.finalized) return;
    p.masterGain = gain;
    p.masterChain = chain ? chain->ptr : nullptr;
    p.masterLimiter = limiter ? limiter->ptr : nullptr;
}

void jm_plan_set_curve(jm_plan *plan, int32_t kind, int32_t index, int32_t what, const int64_t *frames, const float *values, int32_t count) {
    Plan &p = *plan->ptr;
    if (p.finalized || count <= 0 || !frames || !values || what < 0 || what > 2) return;
    Curve *c = nullptr;
    if (kind == 0 && index >= 0 && size_t(index) < p.tracks.size()) {
        Track &t = p.tracks[size_t(index)];
        c = what == 0 ? &t.curve : what == 1 ? &t.muteCurve : &t.panCurve;
    } else if (kind == 1 && index >= 0 && size_t(index) < p.buses.size()) {
        Bus &b = p.buses[size_t(index)];
        c = what == 0 ? &b.curve : what == 1 ? &b.muteCurve : &b.panCurve;
    } else if (kind == 2 && what == 0) {
        c = &p.masterCurve;
    }
    if (!c) return;
    c->kind = Curve::Kind(what);
    c->frames.clear();
    c->db.clear();
    // Kept only where the frames strictly rise and the values are numbers; a curve that isn't so is not half used.
    for (int32_t i = 0; i < count; ++i) {
        if ((i > 0 && frames[i] <= frames[i - 1]) || !std::isfinite(values[i])) { c->frames.clear(); c->db.clear(); return; }
        c->frames.push_back(frames[i]);
        c->db.push_back(values[i]);
    }
}

void jm_plan_set_send_curve(jm_plan *plan, bool fromBus, int32_t from, int32_t to, const int64_t *frames, const float *db, int32_t count) {
    Plan &p = *plan->ptr;
    if (p.finalized || count <= 0 || !frames || !db || from < 0) return;
    std::vector<Send> *sends = nullptr;
    if (fromBus) { if (size_t(from) < p.buses.size()) sends = &p.buses[size_t(from)].sends; }
    else if (size_t(from) < p.tracks.size()) sends = &p.tracks[size_t(from)].sends;
    if (!sends) return;
    for (Send &s : *sends) {
        if (s.bus != to) continue;
        s.curve.kind = Curve::kDecibel;
        s.curve.frames.clear();
        s.curve.db.clear();
        for (int32_t i = 0; i < count; ++i) {
            if ((i > 0 && frames[i] <= frames[i - 1]) || !std::isfinite(db[i])) { s.curve.frames.clear(); s.curve.db.clear(); return; }
            s.curve.frames.push_back(frames[i]);
            s.curve.db.push_back(db[i]);
        }
        return;
    }
}

void jm_plan_set_gain_curve(jm_plan *plan, int32_t kind, int32_t index, const int64_t *frames, const float *db, int32_t count) {
    jm_plan_set_curve(plan, kind, index, 0, frames, db, count);
}

int64_t jm_plan_total_latency(const jm_plan *plan) { return plan->ptr->graph ? plan->ptr->graph->total + plan->ptr->graph->masterLatency : 0; }
int64_t jm_plan_master_latency(const jm_plan *plan) { return plan->ptr->graph ? plan->ptr->graph->masterLatency : 0; }

int64_t jm_plan_compensation(const jm_plan *plan, bool bus, int32_t index) {
    const Plan &p = *plan->ptr;
    if (!p.graph || index < 0) return 0;
    const auto &v = bus ? p.graph->busDelay : p.graph->trackDelay;
    return size_t(index) < v.size() ? v[size_t(index)] : 0;
}

void jm_plan_set_chain(jm_plan *plan, int32_t track, jm_chain *chain) {
    Plan &p = *plan->ptr;
    if (p.finalized || track < 0 || size_t(track) >= p.tracks.size()) return;
    p.tracks[size_t(track)].chain = chain->ptr;
}

void jm_plan_finalize(jm_plan *plan) {
    Plan &p = *plan->ptr;
    if (p.finalized) return;
    std::stable_sort(p.clips.begin(), p.clips.end(), [](const Clip &a, const Clip &b) { return a.start < b.start; });
    p.length = 0;
    for (const Clip &c : p.clips) p.length = std::max(p.length, c.end());
    // The buses, each before every bus it feeds, through its output or a send. A bus caught in a loop
    // (the document model refuses those; this is the engine not trusting it) loses the route that closes it.
    const size_t nb = p.buses.size();
    p.busOrder.clear();
    std::vector<int> state(nb, 0); // 0 not seen, 1 on the path, 2 placed
    std::vector<int32_t> placed;   // every bus after all the buses it feeds
    struct Frame { int32_t bus; size_t next; };
    for (size_t first = 0; first < nb; ++first) {
        if (state[first] != 0) continue;
        std::vector<Frame> stack{{int32_t(first), 0}};
        state[first] = 1;
        while (!stack.empty()) {
            Frame &f = stack.back();
            Bus &bus = p.buses[size_t(f.bus)];
            // Edge 0 is the output, the rest are the sends.
            if (f.next > bus.sends.size()) {
                state[size_t(f.bus)] = 2;
                placed.push_back(f.bus);
                stack.pop_back();
                continue;
            }
            const size_t edge = f.next++;
            int32_t &to = edge == 0 ? bus.output : bus.sends[edge - 1].bus;
            if (to < 0 || size_t(to) >= nb) continue;
            if (state[size_t(to)] == 1) { to = -1; continue; }   // would close a loop: cut
            if (state[size_t(to)] == 0) {
                state[size_t(to)] = 1;
                stack.push_back({to, 0});
            }
        }
    }
    p.busOrder.assign(placed.rbegin(), placed.rend());
    // Keys: every strip is then a node, and each must come after the strips it is fed by or listens to.
    // Keys that point at nothing are dropped; and a key that would close a loop (through routes, sends
    // or other keys) is dropped too, the last given first, until an order exists.
    const size_t nt = p.tracks.size();
    auto real = [&](const Plan::Key &k) {
        const size_t fromCount = k.fromBus ? nb : nt, toCount = k.toBus ? nb : nt;
        if (k.from < 0 || size_t(k.from) >= fromCount || k.to < 0 || size_t(k.to) >= toCount || k.unit < 0) return false;
        if (k.fromBus == k.toBus && k.from == k.to) return false;
        const auto &chain = k.toBus ? p.buses[size_t(k.to)].chain : p.tracks[size_t(k.to)].chain;
        return chain && size_t(k.unit) < chain->units.size();
    };
    p.keys.erase(std::remove_if(p.keys.begin(), p.keys.end(), [&](const Plan::Key &k) { return !real(k); }), p.keys.end());
    p.nodeOrder.clear();
    for (;;) {
        const size_t nodes = nt + nb;
        std::vector<std::vector<int32_t>> next(nodes);
        std::vector<int> waiting(nodes, 0);
        auto edge = [&](size_t from, size_t to) { next[from].push_back(int32_t(to)); ++waiting[to]; };
        for (size_t t = 0; t < nt; ++t) {
            const Track &track = p.tracks[t];
            if (track.bus >= 0 && size_t(track.bus) < nb) edge(t, nt + size_t(track.bus));
            for (const Send &s : track.sends)
                if (s.bus >= 0 && size_t(s.bus) < nb) edge(t, nt + size_t(s.bus));
        }
        for (size_t b = 0; b < nb; ++b) {
            const Bus &bus = p.buses[b];
            if (bus.output >= 0 && size_t(bus.output) < nb) edge(nt + b, nt + size_t(bus.output));
            for (const Send &s : bus.sends)
                if (s.bus >= 0 && size_t(s.bus) < nb && size_t(s.bus) != b) edge(nt + b, nt + size_t(s.bus));
        }
        for (const Plan::Key &k : p.keys) edge(size_t(k.from) + (k.fromBus ? nt : 0), size_t(k.to) + (k.toBus ? nt : 0));
        // Among the strips that are ready, always the one that the older paths would have taken first:
        // the tracks in their order, then the buses in theirs. Sums are then made in the same order as
        // before, so the same project gives the same bits, and a key changes the order only as far as it must.
        std::vector<int32_t> rank(nodes, 0);
        for (size_t t = 0; t < nt; ++t) rank[t] = int32_t(t);
        for (size_t i = 0; i < p.busOrder.size(); ++i) rank[nt + size_t(p.busOrder[i])] = int32_t(nt + i);
        std::vector<int32_t> order;
        std::vector<bool> placedNode(nodes, false);
        for (size_t step = 0; step < nodes; ++step) {
            int32_t best = -1;
            for (size_t n = 0; n < nodes; ++n)
                if (!placedNode[n] && waiting[n] == 0 && (best < 0 || rank[n] < rank[size_t(best)])) best = int32_t(n);
            if (best < 0) break; // a loop: what is left can't be ordered
            placedNode[size_t(best)] = true;
            order.push_back(best);
            for (int32_t m : next[size_t(best)]) --waiting[size_t(m)];
        }
        if (order.size() == nodes) { p.nodeOrder = std::move(order); break; }
        if (p.keys.empty()) break; // (can't be: routes and sends alone never loop here; they were cut above)
        p.keys.pop_back();
    }
    p.graph = std::make_shared<Graph>(p);
    p.finalized = true;
}

void jm_plan_release(jm_plan *plan) { delete plan; }
int64_t jm_plan_length(const jm_plan *plan) { return plan->ptr->length; }
int32_t jm_plan_channels(const jm_plan *plan) { return plan->ptr->channels; }

bool jm_render(const jm_plan *plan, int64_t start, int64_t frames, float *interleaved) {
    if (!plan->ptr->finalized || frames < 0) return false;
    Renderer r(plan->ptr->channels);
    // Fixed slices keep scratch bounded; output doesn't depend on the slice size.
    constexpr int64_t slice = 65536;
    for (int64_t done = 0; done < frames; done += slice) {
        const int64_t n = std::min(slice, frames - done);
        r.render(*plan->ptr, start + done, n, interleaved + done * plan->ptr->channels);
    }
    return true;
}

} // extern "C"
