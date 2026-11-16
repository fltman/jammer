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

/// Adds `n` interleaved frames of `in` to `to`, times `gain`, with the pan's two gains on a stereo signal.
static inline void addStrip(const float *in, float *to, int64_t n, int32_t channels, float gain, float panL, float panR) {
    if (channels == 2) {
        const float l = gain * panL, r = gain * panR;
        for (int64_t i = 0; i < n; ++i) {
            to[i * 2] += in[i * 2] * l;
            to[i * 2 + 1] += in[i * 2 + 1] * r;
        }
    } else {
        for (int64_t i = 0; i < n * channels; ++i) to[i] += in[i] * gain;
    }
}

/// The mix through the buses: each track into its bus or the output, then each bus into the one it
/// feeds, in the order finalize worked out.
void Renderer::renderRouted(const Plan &plan, int64_t start, int64_t frames, float *out) {
    const size_t samples = size_t(frames * channels_);
    std::memset(out, 0, samples * sizeof(float));
    bus_.resize(plan.buses.size());
    for (auto &b : bus_) b.assign(samples, 0.0f);
    track_.resize(samples);
    for (size_t t = 0; t < plan.tracks.size(); ++t) {
        const Track &track = plan.tracks[t];
        if (track.mute) continue;
        if (track.chain) track.chain->process(plan, int32_t(t), *this, start, frames, track_.data());
        else renderTrack(plan, int32_t(t), start, frames, track_.data());
        float *to = track.bus >= 0 && size_t(track.bus) < bus_.size() ? bus_[size_t(track.bus)].data() : out;
        addStrip(track_.data(), to, frames, channels_, track.gain, track.panL, track.panR);
    }
    for (int32_t b : plan.busOrder) {
        const Bus &bus = plan.buses[size_t(b)];
        if (bus.mute) continue;
        float *to = bus.output >= 0 && size_t(bus.output) < bus_.size() ? bus_[size_t(bus.output)].data() : out;
        addStrip(bus_[size_t(b)].data(), to, frames, channels_, bus.gain, bus.panL, bus.panR);
    }
}

void Renderer::render(const Plan &plan, int64_t start, int64_t frames, float *out) {
    if (plan.routed) { renderRouted(plan, start, frames, out); return; }
    std::memset(out, 0, size_t(frames * channels_) * sizeof(float));
    const int64_t end = start + frames;
    for (const Clip &c : plan.clips) {
        if (c.start >= end) break; // sorted by start
        if (c.end() <= start) continue;
        const Track &track = plan.tracks[size_t(c.track)];
        if (track.mute) continue;
        if (track.chain) continue;
        mixClip(plan, c, track.gain, start, frames, out);
    }
    // Tracks with inserts run whenever they're audible, so tails ring past their clips.
    for (size_t t = 0; t < plan.tracks.size(); ++t) {
        const Track &track = plan.tracks[t];
        if (track.mute || !track.chain) continue;
        track_.resize(size_t(frames * channels_));
        track.chain->process(plan, int32_t(t), *this, start, frames, track_.data());
        const float g = track.gain;
        for (int64_t i = 0; i < frames * channels_; ++i) out[i] += track_[size_t(i)] * g;
    }
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
    plan->ptr->tracks.push_back(Track{gain, mute, nullptr});
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
    p.buses.push_back(Bus{gain, mute, pan_l, pan_r, -1});
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
    // The buses, each before the one it feeds. A bus caught in a loop (the document model refuses
    // those; this is the engine not trusting it) goes straight to the output instead.
    p.busOrder.clear();
    std::vector<int> state(p.buses.size(), 0); // 0 not seen, 1 being placed, 2 placed
    std::vector<int32_t> reversed;
    for (size_t first = 0; first < p.buses.size(); ++first) {
        std::vector<int32_t> path;
        int32_t b = int32_t(first);
        while (b >= 0 && state[size_t(b)] == 0) {
            state[size_t(b)] = 1;
            path.push_back(b);
            b = p.buses[size_t(b)].output;
        }
        if (b >= 0 && state[size_t(b)] == 1) p.buses[size_t(path.back())].output = -1; // closes a loop: cut it here
        for (auto it = path.rbegin(); it != path.rend(); ++it) { state[size_t(*it)] = 2; reversed.push_back(*it); }
    }
    // `reversed` has every bus after the one it feeds; the sum runs the other way.
    p.busOrder.assign(reversed.rbegin(), reversed.rend());
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
