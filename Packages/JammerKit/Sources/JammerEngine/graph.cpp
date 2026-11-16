// The mixer when a bus has plugins: delay compensation across buses and sends. See Graph in internal.hpp.

#include "internal.hpp"

#include <algorithm>
#include <cstring>

namespace jm {

Graph::Graph(const Plan &plan) : channels_(plan.channels) {
    const size_t nb = plan.buses.size();
    busLatency.assign(nb, 0);
    for (size_t b = 0; b < nb; ++b) {
        if (!plan.buses[b].chain) continue;
        busLatency[b] = plan.buses[b].chain->latency;
        preroll_ = std::max(preroll_, plan.buses[b].chain->preroll);
    }
    for (const auto &c : {plan.masterChain, plan.masterLimiter}) {
        if (!c) continue;
        masterLatency += c->latency;
        preroll_ = std::max(preroll_, c->preroll);
    }
    auto valid = [nb](int32_t to) { return to >= 0 && size_t(to) < nb ? to : -1; };
    trackEdges_.resize(plan.tracks.size());
    for (size_t t = 0; t < plan.tracks.size(); ++t) {
        const Track &track = plan.tracks[t];
        trackEdges_[t].push_back(Edge(valid(track.bus), 1.0f, false, true));
        for (const Send &s : track.sends)
            if (valid(s.bus) >= 0) trackEdges_[t].push_back(Edge(s.bus, s.gain, s.pre, false));
    }
    busEdges_.resize(nb);
    for (size_t b = 0; b < nb; ++b) {
        const Bus &bus = plan.buses[b];
        busEdges_[b].push_back(Edge(valid(bus.output), 1.0f, false, true));
        for (const Send &s : bus.sends)
            if (valid(s.bus) >= 0 && size_t(s.bus) != b) busEdges_[b].push_back(Edge(s.bus, s.gain, s.pre, false));
    }
    // How late the signal is where it arrives at each bus, and where it leaves: the longest path in.
    // `busOrder` has every bus before the ones it feeds, so one pass is enough. A track leaves on time:
    // its own chain makes up for its plugins by itself.
    std::vector<int64_t> in(nb, 0), outLat(nb, 0);
    total = 0;
    for (int32_t b : plan.busOrder) {
        outLat[size_t(b)] = in[size_t(b)] + busLatency[size_t(b)];
        for (const Edge &e : busEdges_[size_t(b)]) {
            if (e.to >= 0) in[size_t(e.to)] = std::max(in[size_t(e.to)], outLat[size_t(b)]);
            else total = std::max(total, outLat[size_t(b)]);
        }
    }
    auto line = [this](Edge &e, int64_t d) {
        e.delay = std::max<int64_t>(0, d);
        e.line.assign(size_t(e.delay * channels_), 0.0f);
        e.at = 0;
    };
    trackDelay.assign(plan.tracks.size(), 0);
    busDelay.assign(nb, 0);
    for (size_t t = 0; t < trackEdges_.size(); ++t) {
        for (Edge &e : trackEdges_[t]) line(e, e.to >= 0 ? in[size_t(e.to)] : total);
        trackDelay[t] = trackEdges_[t][0].delay;
    }
    for (size_t b = 0; b < nb; ++b) {
        for (Edge &e : busEdges_[b]) line(e, (e.to >= 0 ? in[size_t(e.to)] : total) - outLat[b]);
        busDelay[b] = busEdges_[b][0].delay;
    }
    strip_.assign(size_t(kQuantum * channels_), 0.0f);
    mix_.assign(size_t(kQuantum * channels_), 0.0f);
    bus_.assign(nb, std::vector<float>(size_t(kQuantum * channels_), 0.0f));
}

void Graph::reset(const Plan &plan, int64_t start) {
    for (const Bus &b : plan.buses)
        if (b.chain) b.chain->restart();
    if (plan.masterChain) plan.masterChain->restart();
    if (plan.masterLimiter) plan.masterLimiter->restart();
    for (auto &edges : trackEdges_)
        for (Edge &e : edges) { std::fill(e.line.begin(), e.line.end(), 0.0f); e.at = 0; }
    for (auto &edges : busEdges_)
        for (Edge &e : edges) { std::fill(e.line.begin(), e.line.end(), 0.0f); e.at = 0; }
    // What comes out of the graph at its time g belongs to the timeline at g − total. To hand over the
    // timeline from `start`, it begins a run-in before that and throws the run-in and the lateness away.
    cursor_ = start - preroll_;
    discard_ = preroll_ + total + masterLatency;
    readPos_ = start;
    fifo_.clear();
    fifoHead_ = 0;
    primed_ = true;
}

/// Adds `n` frames of `in`, times the gains, to where the edge goes, as late as the edge's delay says.
void Graph::send(Edge &e, const float *in, float gainL, float gainR, int64_t n) {
    float *to = e.to >= 0 ? bus_[size_t(e.to)].data() : mix_.data();
    const int32_t ch = channels_;
    if (e.delay == 0) {
        if (ch == 2) {
            for (int64_t i = 0; i < n; ++i) { to[i * 2] += in[i * 2] * gainL; to[i * 2 + 1] += in[i * 2 + 1] * gainR; }
        } else {
            for (int64_t i = 0; i < n * ch; ++i) to[i] += in[i] * gainL;
        }
        return;
    }
    const size_t frames = size_t(e.delay);
    for (int64_t i = 0; i < n; ++i) {
        float *slot = e.line.data() + e.at * size_t(ch);
        for (int32_t c = 0; c < ch; ++c) {
            const float g = ch == 2 && c == 1 ? gainR : gainL;
            const float late = slot[c];
            slot[c] = in[i * ch + c] * g;
            to[i * ch + c] += late;
        }
        e.at = (e.at + 1) % frames;
    }
}

void Graph::produce(const Plan &plan, Renderer &renderer) {
    const int64_t q = kQuantum;
    const size_t samples = size_t(q * channels_);
    std::fill(mix_.begin(), mix_.end(), 0.0f);
    for (auto &b : bus_) std::fill(b.begin(), b.end(), 0.0f);
    for (size_t t = 0; t < plan.tracks.size(); ++t) {
        const Track &track = plan.tracks[t];
        if (track.mute) {
            // A muted strip sends silence, so that its delay lines empty in step with the others.
            std::fill(strip_.begin(), strip_.end(), 0.0f);
        } else if (track.chain) {
            track.chain->process(plan, int32_t(t), renderer, cursor_, q, strip_.data());
        } else {
            renderer.renderTrack(plan, int32_t(t), cursor_, q, strip_.data());
        }
        for (Edge &e : trackEdges_[t]) {
            if (e.main) send(e, strip_.data(), track.gain * track.panL, track.gain * track.panR, q);
            else if (e.pre) send(e, strip_.data(), e.gain, e.gain, q);
            else send(e, strip_.data(), track.gain * e.gain * track.panL, track.gain * e.gain * track.panR, q);
        }
    }
    for (int32_t b : plan.busOrder) {
        const Bus &bus = plan.buses[size_t(b)];
        float *sum = bus_[size_t(b)].data();
        if (bus.chain) bus.chain->stream(sum);
        if (bus.mute) std::memset(sum, 0, samples * sizeof(float));
        // Into a copy: an edge may add to a bus later in the order, never to this one.
        std::memcpy(strip_.data(), sum, samples * sizeof(float));
        for (Edge &e : busEdges_[size_t(b)]) {
            if (e.main) send(e, strip_.data(), bus.gain * bus.panL, bus.gain * bus.panR, q);
            else if (e.pre) send(e, strip_.data(), e.gain, e.gain, q);
            else send(e, strip_.data(), bus.gain * e.gain * bus.panL, bus.gain * e.gain * bus.panR, q);
        }
    }
    // The master: its plugins, its gain, and the limiter last of all.
    if (plan.masterChain) plan.masterChain->stream(mix_.data());
    if (plan.masterGain != 1.0f)
        for (float &x : mix_) x *= plan.masterGain;
    if (plan.masterLimiter) plan.masterLimiter->stream(mix_.data());
    cursor_ += q;
    const int64_t skip = std::min(discard_, q);
    discard_ -= skip;
    fifo_.insert(fifo_.end(), mix_.begin() + std::ptrdiff_t(skip * channels_), mix_.end());
}

void Graph::process(const Plan &plan, Renderer &renderer, int64_t start, int64_t n, float *out) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!primed_ || start != readPos_) reset(plan, start);
    while (int64_t(fifo_.size() / size_t(channels_) - fifoHead_) < n) produce(plan, renderer);
    std::memcpy(out, fifo_.data() + fifoHead_ * size_t(channels_), size_t(n * channels_) * sizeof(float));
    fifoHead_ += size_t(n);
    readPos_ += n;
    if (fifoHead_ * 2 > fifo_.size() / size_t(channels_)) {
        fifo_.erase(fifo_.begin(), fifo_.begin() + std::ptrdiff_t(fifoHead_ * size_t(channels_)));
        fifoHead_ = 0;
    }
}

} // namespace jm
