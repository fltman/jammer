// The mixer: how every plan is rendered. Delay compensation across every path. See Graph in internal.hpp.

#include "internal.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace jm {

double Curve::dbAt(int64_t t) const {
    const size_t i = size_t(std::upper_bound(frames.begin(), frames.end(), t) - frames.begin());
    if (i == 0) return db.front();
    if (i == frames.size()) return db.back();
    const double a = db[i - 1], b = db[i];
    return a + (b - a) * double(t - frames[i - 1]) / double(frames[i] - frames[i - 1]);
}

void Curve::apply(const float *in, float *out, int64_t at, int64_t n, int32_t channels) const {
    // What a value is as a gain on the left and on the right. A pan uses the law of a fixed pan
    // (Mixer.panGains): the side it moves away from falls as a cosine, the other stays.
    struct LR { float l, r; };
    const Kind k = kind;
    auto gains = [k](double v) -> LR {
        if (k == kDecibel) { const float g = v == 0.0 ? 1.0f : float(std::pow(10.0, v / 20.0)); return {g, g}; }
        if (k == kAmplitude) { const float g = float(std::min(1.0, std::max(0.0, v))); return {g, g}; }
        const double p = std::min(1.0, std::max(-1.0, v));
        if (p == 0.0) return {1.0f, 1.0f};
        const float fall = std::fabs(p) == 1.0 ? 0.0f : float(std::cos(std::fabs(p) * 3.14159265358979323846 / 2.0));
        return p < 0 ? LR{1.0f, fall} : LR{fall, 1.0f};
    };
    // How much of the line one piece may span before a straight piece in amplitude strays from it:
    // half a dB of level, a fiftieth of the way across for a pan. An amplitude line is straight already.
    const double most = k == kDecibel ? 0.5 : k == kPan ? 0.02 : 1e30;
    int64_t pos = 0;
    while (pos < n) {
        const int64_t t0 = at + pos;
        // The stretch between two points that t0 is in (or before the first, or after the last), and how
        // steep the line is there. Where it is steep the pieces are shorter: a power of two, at most kPiece.
        const auto next = std::upper_bound(frames.begin(), frames.end(), t0);
        const bool inside = next != frames.begin() && next != frames.end();
        int64_t piece = kPiece;
        if (inside) {
            const size_t i = size_t(next - frames.begin());
            const double perFrame = std::fabs(double(db[i]) - double(db[i - 1])) / double(frames[i] - frames[i - 1]);
            while (piece > 1 && perFrame * double(piece) > most) piece /= 2;
        }
        // The piece t0 is in: from a multiple of `piece` on the timeline (or the point before, if later) to
        // the next multiple (or the next point, if sooner). Its two ends, and so every value in it, depend
        // only on the timeline, never on where this call happens to begin.
        const int64_t base = t0 >= 0 ? t0 / piece * piece : -((-t0 + piece - 1) / piece * piece);
        int64_t a = base, b = base + piece;
        if (next != frames.begin()) a = std::max(a, *(next - 1));
        if (next != frames.end()) b = std::min(b, *next);
        const int64_t end = std::min(at + n, b), len = end - t0;
        const LR ga = gains(dbAt(a)), gb = gains(dbAt(b));
        const float *x = in + pos * channels;
        float *y = out + pos * channels;
        if (ga.l == gb.l && ga.r == gb.r && (ga.l == ga.r || channels != 2)) {
            if (ga.l == 1.0f) { if (x != y) std::memcpy(y, x, size_t(len * channels) * sizeof(float)); }
            else for (int64_t i = 0; i < len * channels; ++i) y[i] = x[i] * ga.l;
        } else {
            const float stepL = (gb.l - ga.l) / float(b - a), stepR = (gb.r - ga.r) / float(b - a);
            for (int64_t i = 0; i < len; ++i) {
                const float u = float(t0 - a + i);
                const float gl = ga.l + stepL * u, gr = ga.r + stepR * u;
                if (channels == 2) { y[i * 2] = x[i * 2] * gl; y[i * 2 + 1] = x[i * 2 + 1] * gr; }
                else for (int32_t c = 0; c < channels; ++c) y[i * channels + c] = x[i * channels + c] * gl;
            }
        }
        pos += len;
    }
}

/// A bus's image turned by an azimuth: each channel with a direction re-panned from it plus the turn (the
/// panner's own gains), others (the LFE) as they are. Worked out at the timeline's grid points and ramped
/// between them, as a track's moving place.
void Graph::turnImage(const PanLayout &layout, const Curve &turn, const float *in, float *out, int64_t at, int64_t q) const {
    constexpr int32_t kMax = 32;
    const int32_t n = std::min(channels_, kMax);
    float m0[kMax][kMax], m1[kMax][kMax];
    auto matrix = [&](int64_t t, float m[kMax][kMax]) {
        const double by = turn.dbAt(t);
        for (int32_t k = 0; k < n; ++k) {
            const double az = size_t(k) < layout.channelAzimuth.size() ? layout.channelAzimuth[size_t(k)] : NAN;
            if (std::isnan(az)) { for (int32_t d = 0; d < n; ++d) m[k][d] = d == k ? 1.0f : 0.0f; continue; }
            layout.gains(az + by, layout.channelElevation[size_t(k)], m[k], n);
        }
    };
    int64_t i = 0;
    while (i < q) {
        const int64_t t = at + i, g = (t / Chain::kQuantum) * Chain::kQuantum;
        const int64_t len = std::min(q - i, g + Chain::kQuantum - t);
        matrix(g, m0);
        matrix(g + Chain::kQuantum, m1);
        for (int64_t j = 0; j < len; ++j, ++i) {
            const float u = float(t + j - g) / float(Chain::kQuantum);
            const float *x = in + i * channels_;
            float *y = out + i * channels_;
            for (int32_t d = 0; d < channels_; ++d) y[d] = 0.0f;
            for (int32_t k = 0; k < n; ++k) {
                if (x[k] == 0.0f) continue;
                for (int32_t d = 0; d < n; ++d) {
                    const float gg = m0[k][d] + (m1[k][d] - m0[k][d]) * u;
                    if (gg != 0.0f) y[d] += x[k] * gg;
                }
            }
        }
    }
}

Graph::Graph(const Plan &plan) : channels_(plan.channels) {
    const size_t nt = plan.tracks.size(), nb = plan.buses.size();
    params_ = !plan.masterParams.empty();
    for (const Track &t : plan.tracks) params_ = params_ || !t.params.empty();
    for (const Bus &b : plan.buses) params_ = params_ || !b.params.empty();
    busLatency.assign(nb, 0);
    for (size_t b = 0; b < nb; ++b) {
        if (!plan.buses[b].chain) continue;
        busLatency[b] = plan.buses[b].chain->latency;
        preroll_ = std::max(preroll_, plan.buses[b].chain->preroll);
    }
    // The tracks' chains run as streams here too, and get their run-in from here.
    for (const Track &t : plan.tracks)
        if (t.chain) preroll_ = std::max(preroll_, t.chain->preroll);
    if (plan.masterChain) masterChainLatency_ = plan.masterChain->latency;
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
            if (valid(s.bus) >= 0) {
                trackEdges_[t].push_back(Edge(s.bus, s.gain, s.pre, false));
                if (!s.curve.empty()) trackEdges_[t].back().curve = &s.curve;
            }
    }
    busEdges_.resize(nb);
    for (size_t b = 0; b < nb; ++b) {
        const Bus &bus = plan.buses[b];
        busEdges_[b].push_back(Edge(valid(bus.output), 1.0f, false, true));
        for (const Send &s : bus.sends)
            if (valid(s.bus) >= 0 && size_t(s.bus) != b) {
                busEdges_[b].push_back(Edge(s.bus, s.gain, s.pre, false));
                if (!s.curve.empty()) busEdges_[b].back().curve = &s.curve;
            }
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
    nodeOut_.assign(nt + nb, 0);
    std::vector<int64_t> &out = nodeOut_;
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
    faded_.assign(size_t(kQuantum * channels_), 0.0f);
    sent_.assign(size_t(kQuantum * channels_), 0.0f);
    turned_.assign(size_t(kQuantum * channels_), 0.0f);
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
    // A plan with a plugin's parameter automated works in blocks that lie on the timeline's own grid
    // (the parameter is set once a block, so where the blocks fall decides what is heard): it begins at
    // the block before the run-in and throws the frames up to it away as well. Every other plan begins
    // exactly where it always did.
    int64_t begin = start - preroll_, extra = 0;
    if (params_) {
        const int64_t aligned = begin >= 0 ? begin / kQuantum * kQuantum : -((-begin + kQuantum - 1) / kQuantum * kQuantum);
        extra = begin - aligned;
        begin = aligned;
    }
    cursor_ = begin;
    discard_ = preroll_ + total + masterLatency + extra;
    readPos_ = start;
    fifo_.clear();
    fifoHead_ = 0;
    primed_ = true;
}

bool Graph::trim(const Plan &plan, Renderer &renderer, int32_t kind, int32_t index, size_t node, const Curve &lane, int64_t at, int64_t q,
                 const float *in, float *out, bool &replaced) {
    replaced = false;
    LiveTrims *live = renderer.live;
    const int32_t s = live ? LiveTrims::slot(kind, index) : -1;
    if (liveLast_.size() <= node) { liveLast_.resize(node + 1, 0.0f); liveOn_.resize(node + 1, false); }
    const bool on = s >= 0 && plan.serial != 0 && live->slots[s].serial.load(std::memory_order_acquire) == plan.serial;
    if (!on) { liveOn_[node] = false; return false; }
    const bool replaces = live->slots[s].replaces.load(std::memory_order_relaxed);
    const float target = live->slots[s].db.load(std::memory_order_relaxed);
    // The first block under the hand starts from where the level was: the lane's value there when the
    // trim stands in its place, nothing added when it comes on top.
    const float from = liveOn_[node] ? liveLast_[node] : (replaces && !lane.empty() ? float(lane.dbAt(at)) : (replaces ? 0.0f : 0.0f));
    liveRamp_.kind = Curve::kDecibel;
    liveRamp_.frames.assign({at, at + q});
    liveRamp_.db.assign({from, target});
    liveRamp_.apply(in, out, at, q, channels_);
    if (!liveOn_[node] && replaces) live->push({s, at, from});
    if (replaces) live->push({s, at + q, target});
    liveOn_[node] = true;
    liveLast_[node] = target;
    replaced = replaces;
    return true;
}

bool Graph::sameShape(const Graph &o) const {
    auto edges = [](const std::vector<std::vector<Edge>> &a, const std::vector<std::vector<Edge>> &b) {
        if (a.size() != b.size()) return false;
        for (size_t i = 0; i < a.size(); ++i) {
            if (a[i].size() != b[i].size()) return false;
            for (size_t k = 0; k < a[i].size(); ++k) {
                const Edge &x = a[i][k], &y = b[i][k];
                if (x.to != y.to || x.pre != y.pre || x.main != y.main || x.delay != y.delay || x.line.size() != y.line.size()
                    || x.keyNode != y.keyNode || x.keyUnit != y.keyUnit) return false;
            }
        }
        return true;
    };
    if (channels_ != o.channels_ || total != o.total || masterLatency != o.masterLatency || preroll_ != o.preroll_ || plain_ != o.plain_ || params_ != o.params_) return false;
    if (order_ != o.order_ || nodeIn_ != o.nodeIn_ || nodeOut_ != o.nodeOut_ || masterChainLatency_ != o.masterChainLatency_) return false;
    if (directLine_.size() != o.directLine_.size() || bus_.size() != o.bus_.size() || keyBuffers_.size() != o.keyBuffers_.size()) return false;
    for (size_t i = 0; i < keyBuffers_.size(); ++i) {
        if (keyBuffers_[i].size() != o.keyBuffers_[i].size()) return false;
        for (size_t k = 0; k < keyBuffers_[i].size(); ++k)
            if (keyBuffers_[i][k].unit != o.keyBuffers_[i][k].unit) return false;
    }
    return edges(trackEdges_, o.trackEdges_) && edges(busEdges_, o.busEdges_);
}

bool Graph::continueFrom(Graph &old) {
    if (this == &old) return true;
    std::scoped_lock lock(mutex_, old.mutex_);
    if (!old.primed_ || !sameShape(old)) return false;
    for (size_t i = 0; i < trackEdges_.size(); ++i)
        for (size_t k = 0; k < trackEdges_[i].size(); ++k) { trackEdges_[i][k].line.swap(old.trackEdges_[i][k].line); trackEdges_[i][k].at = old.trackEdges_[i][k].at; }
    for (size_t i = 0; i < busEdges_.size(); ++i)
        for (size_t k = 0; k < busEdges_[i].size(); ++k) { busEdges_[i][k].line.swap(old.busEdges_[i][k].line); busEdges_[i][k].at = old.busEdges_[i][k].at; }
    directLine_.swap(old.directLine_);
    directAt_ = old.directAt_;
    // (Copied, not swapped: the chains' key feeds point into this graph's own buffers.)
    for (size_t i = 0; i < bus_.size(); ++i)
        if (bus_[i].size() == old.bus_[i].size()) std::copy(old.bus_[i].begin(), old.bus_[i].end(), bus_[i].begin());
    for (size_t i = 0; i < keyBuffers_.size(); ++i)
        for (size_t k = 0; k < keyBuffers_[i].size(); ++k)
            if (keyBuffers_[i][k].data.size() == old.keyBuffers_[i][k].data.size())
                std::copy(old.keyBuffers_[i][k].data.begin(), old.keyBuffers_[i][k].data.end(), keyBuffers_[i][k].data.begin());
    cursor_ = old.cursor_;
    discard_ = old.discard_;
    readPos_ = old.readPos_;
    fifo_.swap(old.fifo_);
    fifoHead_ = old.fifoHead_;
    primed_ = true;
    // The other graph has given its state away: if it is ever used again it starts afresh.
    old.primed_ = false;
    old.fifoHead_ = 0;
    return true;
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
            if (track.mute || track.chain || track.automated() || track.live) continue;
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
            if (plain_ && !track.chain && !track.automated() && !track.live) continue;
            if (track.mute) {
                // A muted strip sends silence, so that its delay lines empty in step with the others.
                std::fill(strip_.begin(), strip_.end(), 0.0f);
            } else {
                // The track's own audio, taken as much earlier as the node is late (so that it meets its
                // keys), through its plugins with those keys.
                renderer.renderTrack(plan, int32_t(t), cursor_ - nodeIn_[t], q, strip_.data());
                if (track.chain) {
                    // The plugins' automated parameters, as they stand where this block enters the strip.
                    for (const ParamCurve &pc : track.params) track.chain->control(size_t(pc.unit), pc.parameter, float(pc.curve.dbAt(cursor_ - nodeIn_[t])));
                    track.chain->stream(strip_.data(), feeds_[t].data(), feeds_[t].size());
                }
            }
            // The fader's automation: read at the strip's own place on the timeline, which is the graph's
            // time less how late the strip is where it leaves. A send before the fader doesn't have it.
            // An automated mute silences the strip as its mute button does: sends before the fader too.
            const float *post = strip_.data();
            if (!track.mute) {
                const int64_t at = cursor_ - nodeOut_[t];
                if (!track.muteCurve.empty()) track.muteCurve.apply(strip_.data(), strip_.data(), at, q, channels_);
                // A level under a hand: in the lane's place, or on top of it.
                bool replaced = false;
                const bool trimmed = renderer.live && trim(plan, renderer, 0, int32_t(t), t, track.curve, at, q, post, faded_.data(), replaced);
                if (trimmed) post = faded_.data();
                if (!replaced && !track.curve.empty()) { track.curve.apply(post, faded_.data(), at, q, channels_); post = faded_.data(); }
                if (!track.panCurve.empty()) { track.panCurve.apply(post, faded_.data(), at, q, channels_); post = faded_.data(); }
            }
            for (Edge &e : trackEdges_[t]) {
                if (e.main || e.keyNode >= 0) { send(e, post, track.gain * track.panL, track.gain * track.panR, q); continue; }
                // A send with automation of its own: its level moves on the strip's timeline, like the fader's.
                const float *from = e.pre ? strip_.data() : post;
                if (e.curve) { e.curve->apply(from, sent_.data(), cursor_ - nodeOut_[t], q, channels_); from = sent_.data(); }
                if (e.pre) send(e, from, e.gain, e.gain, q);
                else send(e, from, track.gain * e.gain * track.panL, track.gain * e.gain * track.panR, q);
            }
        } else {
            const size_t b = size_t(n) - nt;
            const Bus &bus = plan.buses[b];
            float *sum = bus_[b].data();
            if (bus.chain) {
                for (const ParamCurve &pc : bus.params) bus.chain->control(size_t(pc.unit), pc.parameter, float(pc.curve.dbAt(cursor_ - nodeIn_[size_t(n)])));
                bus.chain->stream(sum, feeds_[size_t(n)].data(), feeds_[size_t(n)].size());
            }
            if (bus.mute) std::memset(sum, 0, samples * sizeof(float));
            // Into a copy: an edge may add to a bus later in the order, never to this one.
            std::memcpy(strip_.data(), sum, samples * sizeof(float));
            const float *post = strip_.data();
            if (!bus.mute) {
                const int64_t at = cursor_ - nodeOut_[size_t(n)];
                if (!bus.muteCurve.empty()) bus.muteCurve.apply(strip_.data(), strip_.data(), at, q, channels_);
                bool replaced = false;
                const bool trimmed = renderer.live && trim(plan, renderer, 1, int32_t(b), size_t(n), bus.curve, at, q, post, faded_.data(), replaced);
                if (trimmed) post = faded_.data();
                if (!replaced && !bus.curve.empty()) { bus.curve.apply(post, faded_.data(), at, q, channels_); post = faded_.data(); }
                if (!bus.panCurve.empty()) { bus.panCurve.apply(post, faded_.data(), at, q, channels_); post = faded_.data(); }
                if (!bus.turn.empty()) { turnImage(plan.panLayout, bus.turn, post, turned_.data(), at, q); post = turned_.data(); }
            }
            for (Edge &e : busEdges_[b]) {
                if (e.main || e.keyNode >= 0) { send(e, post, bus.gain * bus.panL, bus.gain * bus.panR, q); continue; }
                const float *from = e.pre ? strip_.data() : post;
                if (e.curve) { e.curve->apply(from, sent_.data(), cursor_ - nodeOut_[size_t(n)], q, channels_); from = sent_.data(); }
                if (e.pre) send(e, from, e.gain, e.gain, q);
                else send(e, from, bus.gain * e.gain * bus.panL, bus.gain * e.gain * bus.panR, q);
            }
        }
    }
    // The master: its plugins, its gain, and the limiter last of all.
    if (plan.masterChain) {
        for (const ParamCurve &pc : plan.masterParams) plan.masterChain->control(size_t(pc.unit), pc.parameter, float(pc.curve.dbAt(cursor_ - total)));
        plan.masterChain->stream(mix_.data());
    }
    if (plan.masterGain != 1.0f)
        for (float &x : mix_) x *= plan.masterGain;
    {
        const int64_t at = cursor_ - total - masterChainLatency_;
        bool replaced = false;
        if (renderer.live) trim(plan, renderer, 2, 0, nt + plan.buses.size(), plan.masterCurve, at, q, mix_.data(), mix_.data(), replaced);
        if (!replaced && !plan.masterCurve.empty()) plan.masterCurve.apply(mix_.data(), mix_.data(), at, q, channels_);
    }
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
