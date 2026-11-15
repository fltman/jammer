#include <metal_stdlib>
using namespace metal;

// One full-screen triangle; the fragment shader looks up each pixel column's
// min/max and lights the pixels between them.

struct Uniforms {
    float2 size;        // drawable size in pixels
    float rulerHeight;  // pixels
    float laneHeight;   // pixels per track
    uint columns;
    uint lanes;
    uint channels;
    float selectionStart; // pixel x, or -1
    float selectionEnd;
    float4 wave;
    float4 waveSelected;
    float4 background;
    float4 laneBackground;
    float4 selectionBackground;
    float4 centerLine;
};

struct VOut {
    float4 position [[position]];
};

vertex VOut waveform_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 waveform_fragment(VOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant float2 *columns [[buffer(1)]]) {
    float x = in.position.x;
    float y = in.position.y; // top-left origin
    if (y < u.rulerHeight) return u.background;
    float laneY = y - u.rulerHeight;
    uint lane = uint(laneY / u.laneHeight);
    if (lane >= u.lanes) return u.background;
    bool selected = u.selectionStart >= 0 && x >= u.selectionStart && x < u.selectionEnd;
    float inLane = laneY - float(lane) * u.laneHeight;
    // A thin gap between lanes.
    if (inLane < 1.0) return u.background;
    float band = (u.laneHeight - 1.0) / float(u.channels);
    uint ch = min(u.channels - 1, uint((inLane - 1.0) / band));
    float inBand = (inLane - 1.0) - float(ch) * band;
    float v = 1.0 - 2.0 * (inBand + 0.5) / band; // +1 top, -1 bottom
    uint col = min(u.columns - 1, uint(x));
    float2 mm = columns[(lane * u.channels + ch) * u.columns + col];
    float halfPixel = 1.0 / band;
    float4 base = selected ? u.selectionBackground : u.laneBackground;
    if (abs(v) < halfPixel) base = mix(base, u.centerLine, u.centerLine.a);
    if (mm.y >= mm.x && v >= mm.x - halfPixel && v <= mm.y + halfPixel) {
        return selected ? u.waveSelected : u.wave;
    }
    return base;
}
