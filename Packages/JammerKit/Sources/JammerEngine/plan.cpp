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
    if (const Placement *pl = plan.sourcePlacement[size_t(c.source)].get(); pl && sc <= 2) {
        // Placed by the surround panner: the gains worked out at each place on the timeline's 512-frame grid
        // and ramped in between, so a moving place glides. (Nothing allocated: a few gains on the stack.)
        constexpr int32_t kMax = 32;
        float g0[2][kMax], g1[2][kMax];
        const int32_t dc = std::min(channels_, kMax);
        auto at = [&](int64_t t, float out[2][kMax]) {
            const double az = pl->azimuth.dbAt(t), el = pl->elevation.dbAt(t);
            if (sc == 1) plan.panLayout.gains(az, el, out[0], dc);
            else { plan.panLayout.gains(az + pl->width / 2, el, out[0], dc); plan.panLayout.gains(az - pl->width / 2, el, out[1], dc); }
        };
        // Between the grid's own points (not the render block's ends), so that where a render starts or
        // how it is cut never changes a sample.
        int64_t i = 0;
        while (i < got) {
            const int64_t t = a + i;
            const int64_t g = (t / Chain::kQuantum) * Chain::kQuantum;
            const int64_t next = std::min(a + got, g + Chain::kQuantum);
            const int64_t len = next - t;
            at(g, g0);
            at(g + Chain::kQuantum, g1);
            for (int64_t j = 0; j < len; ++j, ++i) {
                const float gn = fades ? base * fade_gain(c, a - c.start + i) : base;
                const float u = float(t + j - g) / float(Chain::kQuantum);
                float *o = out + (a - start + i) * channels_;
                const float *s = scratch_.data() + i * sc;
                for (int32_t k = 0; k < sc; ++k) {
                    const float sk = s[k] * gn;
                    for (int32_t ch = 0; ch < dc; ++ch) {
                        const float gg = g0[k][ch] + (g1[k][ch] - g0[k][ch]) * u;
                        if (gg != 0.0f) o[ch] += sk * gg;
                    }
                }
            }
        }
        return;
    }
    if (const FieldTurn *ft = plan.sourceTurn[size_t(c.source)].get(); ft && sc == ft->components) {
        // A sound field turned as it plays: the field's matrix worked out at the grid's points and, between
        // them, a curve through three of them (this one and the next two), so that a turn at a steady speed
        // is followed within the place lanes' tolerance (a straight ramp would be off by its chord, which
        // grows with the order). Only grid points: where a render starts never changes a sample.
        constexpr int32_t kC = FieldTurn::kMaxComponents, kD = FieldTurn::kMaxChannels;
        float m0[kC * kD], m1[kC * kD], m2[kC * kD];
        const int32_t dc = ft->channels;
        int64_t i = 0;
        while (i < got) {
            const int64_t t = a + i;
            const int64_t g = (t / Chain::kQuantum) * Chain::kQuantum;
            const int64_t next = std::min(a + got, g + Chain::kQuantum);
            const int64_t len = next - t;
            ft->matrix(g, m0);
            ft->matrix(g + Chain::kQuantum, m1);
            // Where a lane turns within the next two quanta, a curve through them would overshoot the corner, and
            // a straight line would cut it (by up to the order times the change of speed): there the matrix is
            // also worked out at the lane's own point (m2), and goes straight to it and on to the next grid point.
            const int64_t bendAt = ft->bend(g, g + 2 * Chain::kQuantum);
            const bool curve = bendAt < 0;
            const bool kink = !curve && bendAt < g + Chain::kQuantum;
            if (curve) ft->matrix(g + 2 * Chain::kQuantum, m2);
            else if (kink) ft->matrix(bendAt, m2);
            const float uk = kink ? float(bendAt - g) / float(Chain::kQuantum) : 0;
            for (int64_t j = 0; j < len; ++j, ++i) {
                const float gn = fades ? base * fade_gain(c, a - c.start + i) : base;
                const float u = float(t + j - g) / float(Chain::kQuantum);
                float l0, l1, l2;
                if (curve) { l0 = (u - 1) * (u - 2) * 0.5f; l1 = u * (2 - u); l2 = u * (u - 1) * 0.5f; }
                else if (kink && u < uk) { const float v = u / uk; l0 = 1 - v; l1 = 0; l2 = v; }
                else if (kink) { const float v = (u - uk) / (1 - uk); l0 = 0; l1 = v; l2 = 1 - v; }
                else { l0 = 1 - u; l1 = u; l2 = 0; }
                float *o = out + (a - start + i) * channels_;
                const float *s = scratch_.data() + i * sc;
                for (int32_t k = 0; k < sc; ++k) {
                    const float sk = s[k] * gn;
                    if (sk == 0.0f) continue;
                    const int32_t row = k * dc;
                    for (int32_t ch = 0; ch < dc && ch < channels_; ++ch)
                        o[ch] += sk * (l0 * m0[row + ch] + l1 * m1[row + ch] + (l2 != 0.0f ? l2 * m2[row + ch] : 0.0f));
                }
            }
        }
        return;
    }
    const std::vector<float> &m = plan.sourceMatrix[size_t(c.source)];
    if (!m.empty()) {
        // Through the source's matrix: each source channel into the document's channels by its gains.
        for (int64_t i = 0; i < got; ++i) {
            const float g = fades ? base * fade_gain(c, a - c.start + i) : base;
            float *o = out + (a - start + i) * channels_;
            const float *s = scratch_.data() + i * sc;
            for (int32_t k = 0; k < sc; ++k) {
                const float sk = s[k] * g;
                const float *row = m.data() + size_t(k) * size_t(channels_);
                for (int32_t ch = 0; ch < channels_; ++ch) if (row[ch] != 0.0f) o[ch] += sk * row[ch];
            }
        }
        return;
    }
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
    static std::atomic<uint64_t> made{0};
    p->serial = made.fetch_add(1, std::memory_order_relaxed) + 1;
    return new jm_plan{std::move(p)};
}

int32_t jm_plan_add_source(jm_plan *plan, jm_source *source) {
    plan->ptr->sources.push_back(source->ptr);
    plan->ptr->sourceMatrix.emplace_back();
    plan->ptr->sourcePlacement.emplace_back();
    plan->ptr->sourceTurn.emplace_back();
    return int32_t(plan->ptr->sources.size() - 1);
}

void jm_plan_set_pan_layout(jm_plan *plan, int32_t order, const int32_t *channels, const double *azimuths, const double *elevations, int32_t count) {
    PanLayout &l = plan->ptr->panLayout;
    l = PanLayout();
    l.order = std::clamp(order, 0, 3);
    for (int32_t i = 0; i < count; ++i) {
        if (channels[i] < 0 || channels[i] >= plan->ptr->channels) continue;
        (elevations[i] > 0 ? l.top : l.ear).push_back({channels[i], azimuths[i]});
    }
    l.channelAzimuth.assign(size_t(plan->ptr->channels), NAN);
    l.channelElevation.assign(size_t(plan->ptr->channels), 0.0);
    for (int32_t i = 0; i < count; ++i) {
        if (channels[i] < 0 || channels[i] >= plan->ptr->channels) continue;
        l.channelAzimuth[size_t(channels[i])] = azimuths[i];
        l.channelElevation[size_t(channels[i])] = elevations[i];
    }
    auto byAzimuth = [](const PanLayout::Speaker &a, const PanLayout::Speaker &b) { return a.azimuth < b.azimuth; };
    std::sort(l.ear.begin(), l.ear.end(), byAzimuth);
    std::sort(l.top.begin(), l.top.end(), byAzimuth);
}

void jm_plan_set_bus_turn(jm_plan *plan, int32_t bus, const int64_t *frames, const float *values, int32_t count) {
    Plan &p = *plan->ptr;
    if (bus < 0 || size_t(bus) >= p.buses.size() || count < 1 || p.panLayout.order > 0) return;
    p.buses[size_t(bus)].turn.frames.assign(frames, frames + count);
    p.buses[size_t(bus)].turn.db.assign(values, values + count);
}

void jm_plan_set_source_placement(jm_plan *plan, int32_t source, const int64_t *az_frames, const float *az_values, int32_t az_count,
                                  const int64_t *el_frames, const float *el_values, int32_t el_count, double width) {
    Plan &p = *plan->ptr;
    if (source < 0 || size_t(source) >= p.sources.size() || az_count < 1 || el_count < 1 || p.sources[size_t(source)]->channels > 2) return;
    auto pl = std::make_shared<Placement>();
    pl->azimuth.frames.assign(az_frames, az_frames + az_count);
    pl->azimuth.db.assign(az_values, az_values + az_count);
    pl->elevation.frames.assign(el_frames, el_frames + el_count);
    pl->elevation.db.assign(el_values, el_values + el_count);
    pl->width = width;
    p.sourcePlacement[size_t(source)] = pl;
}

namespace {
/// The real spherical harmonics of AmbiX (ACN, SN3D) up to `order` for a direction, as the app's
/// `Ambisonics.encode`. Nothing allocated.
void field_harmonics(double az, double el, int32_t order, double *y) JM_NONBLOCKING {
    const double cp = std::cos(az), sp = std::sin(az), ct = std::cos(el), st = std::sin(el);
    y[0] = 1;
    if (order >= 1) { y[1] = sp * ct; y[2] = st; y[3] = cp * ct; }
    if (order >= 2) {
        const double r3 = 1.7320508075688772;
        y[4] = r3 / 2 * std::sin(2 * az) * ct * ct; y[5] = r3 / 2 * sp * std::sin(2 * el); y[6] = 0.5 * (3 * st * st - 1);
        y[7] = r3 / 2 * cp * std::sin(2 * el); y[8] = r3 / 2 * std::cos(2 * az) * ct * ct;
    }
    if (order >= 3) {
        const double a = 0.7905694150420949, b = 1.9364916731037085, c = 0.6123724356957945;
        y[9] = a * std::sin(3 * az) * ct * ct * ct; y[10] = b * std::sin(2 * az) * st * ct * ct; y[11] = c * sp * ct * (5 * st * st - 1);
        y[12] = 0.5 * st * (5 * st * st - 3); y[13] = c * cp * ct * (5 * st * st - 1); y[14] = b * std::cos(2 * az) * st * ct * ct;
        y[15] = a * std::cos(3 * az) * ct * ct * ct;
    }
}
} // namespace

void FieldTurn::matrix(int64_t t, float *out) const JM_NONBLOCKING {
    const double d2r = 3.14159265358979323846 / 180;
    const double r = roll.dbAt(t) * d2r, p = pitch.dbAt(t) * d2r, yw = yaw.dbAt(t) * d2r;
    const double cr = std::cos(r), sr = std::sin(r), cpi = std::cos(p), spi = std::sin(p), cy = std::cos(yw), sy = std::sin(yw);
    double m[kMaxComponents][kMaxComponents] = {};
    double y1[kMaxComponents];
    for (int32_t k = 0; k < kPoints; ++k) {
        // The point turned: roll about the front axis, pitch about the left one, yaw about the vertical.
        const double *v = dir[k];
        const double a1 = v[1] * cr - v[2] * sr, a2 = v[1] * sr + v[2] * cr;
        const double b0 = v[0] * cpi - a2 * spi, b2 = v[0] * spi + a2 * cpi;
        const double x = b0 * cy - a1 * sy, y = b0 * sy + a1 * cy, z = b2;
        field_harmonics(std::atan2(y, x), std::asin(z > 1 ? 1 : z < -1 ? -1 : z), order, y1);
        for (int32_t i = 0; i < components; ++i) {
            const int32_t band = int32_t(std::sqrt(double(i)) + 1e-9);
            const double f = double(2 * band + 1) * weight[k] * y1[i];
            for (int32_t j = band * band; j < (band + 1) * (band + 1); ++j) m[j][i] += f * harmonics[k][j];
        }
    }
    for (int32_t i = 0; i < components; ++i)
        for (int32_t ch = 0; ch < channels; ++ch) {
            double s = 0;
            for (int32_t j = 0; j < components; ++j) s += m[i][j] * double(base[size_t(j * channels + ch)]);
            out[i * channels + ch] = float(s);
        }
}

int64_t FieldTurn::bend(int64_t from, int64_t to) const JM_NONBLOCKING {
    int64_t first = -1;
    for (const Curve *c : {&yaw, &pitch, &roll}) {
        const auto it = std::upper_bound(c->frames.begin(), c->frames.end(), from);
        if (it != c->frames.end() && *it < to && (first < 0 || *it < first)) first = *it;
    }
    return first;
}

void jm_plan_set_source_turn(jm_plan *plan, int32_t source, int32_t order, const float *base,
                             const int64_t *yaw_frames, const float *yaw_values, int32_t yaw_count,
                             const int64_t *pitch_frames, const float *pitch_values, int32_t pitch_count,
                             const int64_t *roll_frames, const float *roll_values, int32_t roll_count) {
    Plan &p = *plan->ptr;
    if (source < 0 || size_t(source) >= p.sources.size() || order < 1 || order > 3 || yaw_count < 1 || pitch_count < 1 || roll_count < 1) return;
    auto f = std::make_shared<FieldTurn>();
    f->order = order;
    f->components = (order + 1) * (order + 1);
    f->channels = p.channels;
    if (p.sources[size_t(source)]->channels != f->components || p.channels > FieldTurn::kMaxChannels) return;
    f->base.assign(base, base + size_t(f->components * p.channels));
    f->yaw.frames.assign(yaw_frames, yaw_frames + yaw_count); f->yaw.db.assign(yaw_values, yaw_values + yaw_count);
    f->pitch.frames.assign(pitch_frames, pitch_frames + pitch_count); f->pitch.db.assign(pitch_values, pitch_values + pitch_count);
    f->roll.frames.assign(roll_frames, roll_frames + roll_count); f->roll.db.assign(roll_values, roll_values + roll_count);
    // Gauss–Legendre in sin(elevation) (4 nodes) times 8 azimuths: exact for the products of harmonics up to order 3.
    const double node[4] = {-0.8611363115940526, -0.3399810435848563, 0.3399810435848563, 0.8611363115940526};
    const double gw[4] = {0.3478548451374538, 0.6521451548625461, 0.6521451548625461, 0.3478548451374538};
    int32_t k = 0;
    for (int32_t i = 0; i < 4; ++i)
        for (int32_t a = 0; a < 8; ++a, ++k) {
            const double az = 2 * 3.14159265358979323846 * a / 8, el = std::asin(node[i]);
            f->dir[k][0] = std::cos(az) * std::cos(el); f->dir[k][1] = std::sin(az) * std::cos(el); f->dir[k][2] = std::sin(el);
            f->weight[k] = gw[i] / 2 / 8;
            field_harmonics(az, el, 3, f->harmonics[k]);
        }
    p.sourceTurn[size_t(source)] = f;
}

namespace {
/// Pairwise amplitude panning on one ring (V. Pulkki, JAES 45(6), 1997), constant power; adds `share` of it.
void pan_ring(const std::vector<PanLayout::Speaker> &ring, double azimuth, double share, float *out) JM_NONBLOCKING {
    if (ring.empty() || share <= 1e-9) return;
    if (ring.size() == 1) { out[ring[0].channel] += float(share); return; }
    auto norm = [](double x) { double y = std::fmod(x, 360.0); return y < 0 ? y + 360.0 : y; };
    for (size_t k = 0; k < ring.size(); ++k) {
        const PanLayout::Speaker &s1 = ring[k], &s2 = ring[(k + 1) % ring.size()];
        const double span = norm(s2.azimuth - s1.azimuth), off = norm(azimuth - s1.azimuth);
        if (span <= 0 || off > span) continue;
        if (off == 0) { out[s1.channel] += float(share); return; }
        if (off == span) { out[s2.channel] += float(share); return; }
        const double r = 3.14159265358979323846 / 180;
        const double t = azimuth * r, t1 = s1.azimuth * r, t2 = s2.azimuth * r;
        const double det = std::cos(t1) * std::sin(t2) - std::sin(t1) * std::cos(t2);
        double g1 = std::max(0.0, (std::cos(t) * std::sin(t2) - std::sin(t) * std::cos(t2)) / det);
        double g2 = std::max(0.0, (std::cos(t1) * std::sin(t) - std::sin(t1) * std::cos(t)) / det);
        const double p = std::sqrt(g1 * g1 + g2 * g2);
        if (p > 0) { out[s1.channel] += float(share * g1 / p); out[s2.channel] += float(share * g2 / p); }
        else out[s1.channel] += float(share);
        return;
    }
    out[ring[0].channel] += float(share);
}
} // namespace

void PanLayout::gains(double azimuth, double elevation, float *out, int32_t channels) const JM_NONBLOCKING {
    for (int32_t c = 0; c < channels; ++c) out[c] = 0.0f;
    if (order > 0) {
        // AmbiX (ACN, SN3D): the real spherical harmonics, as the app's Ambisonics.encode.
        const double r = 3.14159265358979323846 / 180, p = azimuth * r, t = elevation * r;
        const double cp = std::cos(p), sp = std::sin(p), ct = std::cos(t), st = std::sin(t);
        double y[16] = {1, sp * ct, st, cp * ct};
        if (order >= 2) {
            const double r3 = std::sqrt(3.0);
            y[4] = r3 / 2 * std::sin(2 * p) * ct * ct; y[5] = r3 / 2 * sp * std::sin(2 * t); y[6] = 0.5 * (3 * st * st - 1);
            y[7] = r3 / 2 * cp * std::sin(2 * t); y[8] = r3 / 2 * std::cos(2 * p) * ct * ct;
        }
        if (order >= 3) {
            const double a = std::sqrt(5.0 / 8), b = std::sqrt(15.0) / 2, c = std::sqrt(3.0 / 8);
            y[9] = a * std::sin(3 * p) * ct * ct * ct; y[10] = b * std::sin(2 * p) * st * ct * ct; y[11] = c * sp * ct * (5 * st * st - 1);
            y[12] = 0.5 * st * (5 * st * st - 3); y[13] = c * cp * ct * (5 * st * st - 1); y[14] = b * std::cos(2 * p) * st * ct * ct;
            y[15] = a * std::cos(3 * p) * ct * ct * ct;
        }
        const int32_t n = (order + 1) * (order + 1);
        for (int32_t c = 0; c < n && c < channels; ++c) out[c] = float(y[c]);
        return;
    }
    // Loudspeakers: the ear layer and the height layer crossfaded by elevation at constant power, 0° to 30°.
    const double w = top.empty() ? 0.0 : std::min(1.0, std::max(0.0, elevation / 30.0));
    const double half = 3.14159265358979323846 / 2;
    const double a = std::fmod(azimuth, 360.0);
    pan_ring(ear, a, std::cos(w * half), out);
    pan_ring(top, a, std::sin(w * half), out);
}

void jm_plan_set_source_matrix(jm_plan *plan, int32_t source, const float *gains, int32_t source_channels) {
    Plan &p = *plan->ptr;
    if (source < 0 || size_t(source) >= p.sources.size() || source_channels != p.sources[size_t(source)]->channels) return;
    p.sourceMatrix[size_t(source)].assign(gains, gains + size_t(source_channels) * size_t(p.channels));
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

void jm_plan_add_param_curve(jm_plan *plan, int32_t kind, int32_t index, int32_t unit, uint32_t parameter, const int64_t *frames, const float *values, int32_t count) {
    Plan &p = *plan->ptr;
    if (p.finalized || count <= 0 || unit < 0) return;
    ParamCurve pc;
    pc.unit = unit;
    pc.parameter = parameter;
    pc.curve.kind = Curve::kAmplitude;   // a straight line; only read point by point, never applied to the sound
    pc.curve.frames.assign(frames, frames + count);
    pc.curve.db.assign(values, values + count);
    if (kind == 0 && index >= 0 && size_t(index) < p.tracks.size()) p.tracks[size_t(index)].params.push_back(std::move(pc));
    else if (kind == 1 && index >= 0 && size_t(index) < p.buses.size()) p.buses[size_t(index)].params.push_back(std::move(pc));
    else if (kind == 2) p.masterParams.push_back(std::move(pc));
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

extern "C++" {
namespace jm {
/// Whether `next` may go on from where `prev` is playing: the same plugins (the very same chains, whose
/// state then carries on), the same master, and graphs of the same shape. Then the graph's state moves over.
bool continuePlan(Plan &next, Plan &prev) {
    if (&next == &prev) return true;
    if (!next.finalized || !prev.finalized || !next.graph || !prev.graph) return false;
    if (next.channels != prev.channels || next.sampleRate != prev.sampleRate) return false;
    if (next.tracks.size() != prev.tracks.size() || next.buses.size() != prev.buses.size()) return false;
    for (size_t i = 0; i < next.tracks.size(); ++i)
        if (next.tracks[i].chain != prev.tracks[i].chain) return false;
    for (size_t i = 0; i < next.buses.size(); ++i)
        if (next.buses[i].chain != prev.buses[i].chain) return false;
    if (next.masterChain != prev.masterChain) return false;
    if (next.masterLimiter != prev.masterLimiter) return false;
    return next.graph->continueFrom(*prev.graph);
}
} // namespace jm
} // extern "C++"

uint64_t jm_plan_serial(const jm_plan *plan) { return plan->ptr->serial; }
void jm_plan_set_track_live(jm_plan *plan, int32_t track, bool live) {
    if (track >= 0 && size_t(track) < plan->ptr->tracks.size()) plan->ptr->tracks[size_t(track)].live = live;
}

bool jm_plan_continue_from(jm_plan *plan, jm_plan *previous) { return jm::continuePlan(*plan->ptr, *previous->ptr); }

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
