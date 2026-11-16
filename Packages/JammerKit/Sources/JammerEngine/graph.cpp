// The mixer: how every plan is rendered. Delay compensation across every path. See Graph in internal.hpp.

#include "internal.hpp"

#include <algorithm>
#include <cstring>

namespace jm {

Graph::Graph(const Plan &plan) : channels_(plan.channels) {
    const size_t nt = plan.tracks.size(), nb = plan.buses.size();
    busLatency.assign(nb, 0);
    for (size_t b = 0; b < nb; ++b) {
        if (!plan.buses[b].chain) continue;
        busLatency[b] = plan.buses[b].chain->latency;
        preroll_ = std::max(preroll_, plan.buses[b].chain->preroll);
    }
    // The tracks' chains run as streams here too, and get their run-in from here.
    for (const Track &t : plan.tracks)
        if (t.chain) preroll_ = std::max(preroll_, t.chain->preroll);
    for (const auto &c : {plan.masterChain, plan.masterLimiter}) {
        if (!c) continue;
        masterLatency += c->latency;
        preroll_ = std::max(preroll_, c->preroll);
    }
    auto valid = [nb](int32_t to) { return to >= 0 && size_t(to) < nb ? to : -1; };
    trackEdges_.resize(nt);
    for (size_t t = 0; t < nt; ++t) {
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
    // Keys: an edge from the source strip, after its fader, to one unit of the listening strip's chain.
    keyBuffers_.resize(nt + nb);
    feeds_.resize(nt + nb);
    for (const Plan::Key &k : plan.keys) {
        const size_t from = size_t(k.from) + (k.fromBus ? nt : 0), to = size_t(k.to) + (k.toBus ? nt : 0);
        Edge e(-1, 1.0f, false, false);
        e.keyNode = int32_t(to);
        e.keyUnit = k.unit;
        (k.fromBus ? busEdges_[size_t(k.from)] : trackEdges_[size_t(k.from)]).push_back(std::move(e));
        keyBuffers_[to].push_back(KeyBuffer{k.unit, std::vector<float>(size_t(kQuantum * channels_), 0.0f)});
        (void)from;
    }
    for (size_t n = 0; n < keyBuffers_.size(); ++n)
        for (const KeyBuffer &kb : keyBuffers_[n]) feeds_[n].push_back(Chain::KeyFeed{kb.unit, kb.data.data()});

    // The order the strips are worked through in: the one finalize found, in which every strip comes
    // after the strips that feed it or that it listens to (the tracks in their order, then the buses,
    // wherever nothing forces another).
    order_ = plan.nodeOrder;
    // How late the signal is where it arrives at each strip, and where it leaves: the longest path in.
    // One pass in that order is enough. A track's chain is a stream like a bus's, and makes the track
    // as late as its plugins are.
    nodeIn_.assign(nt + nb, 0);
    std::vector<int64_t> out(nt + nb, 0);
    total = 0;
    for (int32_t n : order_) {
        const bool isBus = size_t(n) >= nt;
        const size_t i = isBus ? size_t(n) - nt : size_t(n);
        int64_t own = 0;
        if (isBus) own = busLatency[i];
        else if (plan.tracks[i].chain) own = plan.tracks[i].chain->latency;
        out[size_t(n)] = nodeIn_[size_t(n)] + own;
        for (const Edge &e : isBus ? busEdges_[i] : trackEdges_[i]) {
            if (e.keyNode >= 0) nodeIn_[size_t(e.keyNode)] = std::max(nodeIn_[size_t(e.keyNode)], out[size_t(n)]);
            else if (e.to >= 0) nodeIn_[nt + size_t(e.to)] = std::max(nodeIn_[nt + size_t(e.to)], out[size_t(n)]);
            else total = std::max(total, out[size_t(n)]);
        }
    }
    auto line = [this](Edge &e, int64_t d) {
        e.delay = std::max<int64_t>(0, d);
        e.line.assign(size_t(e.delay * channels_), 0.0f);
        e.at = 0;
    };
    auto arrival = [&](const Edge &e) { return e.keyNode >= 0 ? nodeIn_[size_t(e.keyNode)] : e.to >= 0 ? nodeIn_[nt + size_t(e.to)] : total; };
    trackDelay.assign(nt, 0);
    busDelay.assign(nb, 0);
    for (size_t t = 0; t < nt; ++t) {
        for (Edge &e : trackEdges_[t]) line(e, arrival(e) - out[t]);
        trackDelay[t] = trackEdges_[t][0].delay;
    }
    for (size_t b = 0; b < nb; ++b) {
        for (Edge &e : busEdges_[b]) line(e, arrival(e) - out[nt + b]);
        busDelay[b] = busEdges_[b][0].delay;
    }
    plain_ = !plan.routed && plan.keys.empty();
    if (plain_) {
        direct_.assign(size_t(kQuantum * channels_), 0.0f);
        directLine_.assign(size_t(total * channels_), 0.0f);
    }
    strip_.assign(size_t(kQuantum * channels_), 0.0f);
    mix_.assign(size_t(kQuantum * channels_), 0.0f);
    bus_.assign(nb, std::vector<float>(size_t(kQuantum * channels_), 0.0f));
}

void Graph::reset(const Plan &plan, int64_t start) {
    for (const Bus &b : plan.buses)
        if (b.chain) b.chain->restart();
    for (const Track &t : plan.tracks)
        if (t.chain) t.chain->restart();
    if (plan.masterChain) plan.masterChain->restart();
    if (plan.masterLimiter) plan.masterLimiter->restart();
    for (auto &edges : trackEdges_)
        for (Edge &e : edges) { std::fill(e.line.begin(), e.line.end(), 0.0f); e.at = 0; }
    for (auto &edges : busEdges_)
        for (Edge &e : edges) { std::fill(e.line.begin(), e.line.end(), 0.0f); e.at = 0; }
    std::fill(directLine_.begin(), directLine_.end(), 0.0f);
    directAt_ = 0;
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
    float *to = mix_.data();
    if (e.keyNode >= 0) {
        // (A strip has few keys; the one for this unit is found by looking.)
        to = nullptr;
        for (KeyBuffer &kb : keyBuffers_[size_t(e.keyNode)])
            if (kb.unit == e.keyUnit) { to = kb.data.data(); break; }
        if (!to) return;
    } else if (e.to >= 0) {
        to = bus_[size_t(e.to)].data();
    }
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
    const size_t nt = plan.tracks.size();
    std::fill(mix_.begin(), mix_.end(), 0.0f);
    for (auto &b : bus_) std::fill(b.begin(), b.end(), 0.0f);
    for (auto &node : keyBuffers_)
        for (KeyBuffer &kb : node) std::fill(kb.data.begin(), kb.data.end(), 0.0f);
    if (plain_) {
        // The tracks without plugins, as the plain renderer sums them: every clip in the order of their
        // starts, the track's gain folded into the clip's. Then as late as the longest path.
        std::fill(direct_.begin(), direct_.end(), 0.0f);
        const int64_t end = cursor_ + q;
        for (const Clip &c : plan.clips) {
            if (c.start >= end) break;
            if (c.end() <= cursor_) continue;
            const Track &track = plan.tracks[size_t(c.track)];
            if (track.mute || track.chain) continue;
            renderer.mixClip(plan, c, track.gain, cursor_, q, direct_.data());
        }
        if (total == 0) {
            std::memcpy(mix_.data(), direct_.data(), samples * sizeof(float));
        } else {
            const size_t frames = size_t(total);
            for (int64_t i = 0; i < q; ++i) {
                float *slot = directLine_.data() + directAt_ * size_t(channels_);
                for (int32_t c = 0; c < channels_; ++c) {
                    mix_[size_t(i * channels_ + c)] = slot[c];
                    slot[c] = direct_[size_t(i * channels_ + c)];
                }
                directAt_ = (directAt_ + 1) % frames;
            }
        }
    }
    for (int32_t n : order_) {
        if (size_t(n) < nt) {
            const size_t t = size_t(n);
            const Track &track = plan.tracks[t];
            // (In a plain plan the tracks without plugins are in the sum already.)
            if (plain_ && !track.chain) continue;
            if (track.mute) {
                // A muted strip sends silence, so that its delay lines empty in step with the others.
                std::fill(strip_.begin(), strip_.end(), 0.0f);
            } else {
                // The track's own audio, taken as much earlier as the node is late (so that it meets its
                // keys), through its plugins with those keys.
                renderer.renderTrack(plan, int32_t(t), cursor_ - nodeIn_[t], q, strip_.data());
                if (track.chain) track.chain->stream(strip_.data(), feeds_[t].data(), feeds_[t].size());
            }
            for (Edge &e : trackEdges_[t]) {
                if (e.main || e.keyNode >= 0) send(e, strip_.data(), track.gain * track.panL, track.gain * track.panR, q);
                else if (e.pre) send(e, strip_.data(), e.gain, e.gain, q);
                else send(e, strip_.data(), track.gain * e.gain * track.panL, track.gain * e.gain * track.panR, q);
            }
        } else {
            const size_t b = size_t(n) - nt;
            const Bus &bus = plan.buses[b];
            float *sum = bus_[b].data();
            if (bus.chain) bus.chain->stream(sum, feeds_[size_t(n)].data(), feeds_[size_t(n)].size());
            if (bus.mute) std::memset(sum, 0, samples * sizeof(float));
            // Into a copy: an edge may add to a bus later in the order, never to this one.
            std::memcpy(strip_.data(), sum, samples * sizeof(float));
            for (Edge &e : busEdges_[b]) {
                if (e.main || e.keyNode >= 0) send(e, strip_.data(), bus.gain * bus.panL, bus.gain * bus.panR, q);
                else if (e.pre) send(e, strip_.data(), e.gain, e.gain, q);
                else send(e, strip_.data(), bus.gain * e.gain * bus.panL, bus.gain * e.gain * bus.panR, q);
            }
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
