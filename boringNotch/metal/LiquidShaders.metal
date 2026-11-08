//
//  LiquidShaders.metal
//  boringNotch
//
//  GPU shaders for the notch's liquid visuals.
//
//  ferrofluid: the music visualiser, a flowing ribbon of fine strings driven
//  by the frequency bands, with ripples on the beat.
//
//  liquidGlass: refraction for the custom glass. Bends the captured backdrop
//  at the edges of each glass tile, with slight chromatic dispersion, frost
//  inside the tiles and a lit rim.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Liquid visualiser

// A flowing ribbon of fine luminous strings. All the strings follow one shared
// wave and fan out slightly from each other, so they read as a single piece of
// silk. Height follows the music along the ribbon (bass in the middle, highs
// towards the ends), beats send a ripple outward from the centre, and colour
// runs through the album palette. Both ends taper and fade to nothing.

constant int STRINGS = 14;

float3 paletteAt(float x, device const float *cols, int n) {
    if (n <= 1) return float3(cols[0], cols[1], cols[2]);
    float f = clamp(x, 0.0, 1.0) * float(n - 1);
    int i = min(int(floor(f)), n - 2);
    float t = smoothstep(0.0, 1.0, f - float(i));
    float3 a = float3(cols[i * 4 + 0], cols[i * 4 + 1], cols[i * 4 + 2]);
    float3 b = float3(cols[(i + 1) * 4 + 0], cols[(i + 1) * 4 + 1], cols[(i + 1) * 4 + 2]);
    return mix(a, b, t);
}

/// Band level along the ribbon: bass at the centre, highs at the ends.
float bandAlong(float u, float4 bands) {
    float a = min(abs(u) * 3.0, 2.999);
    int i = int(floor(a));
    float t = smoothstep(0.0, 1.0, a - float(i));
    return mix(bands[i], bands[i + 1], t);
}

/// String height in points from the centre line. k is -1...1 across the ribbon.
float ribbonHeight(float u, float k, float time, float4 bands, float beat, float ripple, float h) {
    float x = u * 3.0;
    float taper = 1.0 - smoothstep(0.55, 1.0, abs(u));
    float amp = h * (0.07 + 0.34 * bandAlong(u, bands) + 0.04 * beat);

    float wave = sin(x * 1.15 + time * 0.75 + k * 0.85) * 0.62
               + sin(x * 2.3 - time * 1.05 + k * 1.5) * 0.28
               + sin(x * 0.5 + time * 0.4) * 0.25;

    // Smooth abs() so the ripple has no kink at the centre.
    float rip = sin(sqrt(x * x + 0.25) * 6.0 - time * 6.0 + k * 0.6) * 0.3 * (0.3 + ripple) * beat;

    float s = sin(x * 0.9 - time * 0.5);
    float spread = h * 0.10 * k * (0.35 + 0.65 * s * s);

    return (amp * (wave + rip) + spread) * taper;
}

[[ stitchable ]] half4 ferrofluid(float2 localPos,
                                  float2 origin,     // where this view sits in the panel
                                  float2 size,       // the whole panel
                                  float time,
                                  float4 bands,      // bass, low-mid, mid, high (0...1)
                                  float beat,        // 0...1 envelope
                                  float ripple,      // user setting: beat ripple strength
                                  device const float *cols, int colCount)
{
    int nColors = max(colCount / 4, 1);
    float2 pos = localPos + origin;
    float midY = size.y * 0.55;
    float u = pos.x / size.x * 2.0 - 1.0;
    float du = 2.0 / size.x;

    float fade = smoothstep(0.0, 0.28, 1.0 - abs(u));
    if (fade <= 0.0) return half4(0.0);

    float3 light = float3(0.0);
    for (int i = 0; i < STRINGS; i++) {
        float k = float(i) / float(STRINGS - 1) * 2.0 - 1.0;
        float y0 = ribbonHeight(u, k, time, bands, beat, ripple, size.y);
        float y1 = ribbonHeight(u + du, k, time, bands, beat, ripple, size.y);
        float slope = y1 - y0;
        float d = abs(pos.y - (midY + y0)) / sqrt(1.0 + slope * slope);
        if (d > 26.0) continue;

        float3 c = paletteAt((0.5 + 0.5 * u) * 0.7 + (0.5 + 0.5 * k) * 0.3, cols, nColors);
        float core = 1.0 - smoothstep(0.35, 1.5, d);
        float glow = exp(-d / 4.5) * 0.10;
        light += c * (core * 0.55 + glow) * (1.0 - 0.55 * abs(k));
    }

    // Filmic roll-off keeps overlaps colourful instead of blowing out to white.
    float3 rgb = (1.0 - exp(-light * fade * 2.4));
    float a = clamp(max(max(rgb.r, rgb.g), rgb.b), 0.0, 1.0);
    return half4(half3(rgb), half(a));
}

// MARK: - Liquid glass refraction

float sdRoundRect(float2 p, float2 center, float2 halfSize, float radius) {
    float2 q = abs(p - center) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

/// rects: (x, y, w, h, radius) per tile, in the layer's coordinates.
[[ stitchable ]] half4 liquidGlass(float2 pos,
                                   SwiftUI::Layer layer,
                                   float2 size,
                                   float refraction,   // 0...1
                                   float frost,        // 0...1
                                   device const float *rects, int rectCount)
{
    int n = rectCount / 5;
    float bestD = 1e9;
    float2 c = float2(0.0), h = float2(1.0);
    float r = 0.0;
    for (int i = 0; i < n; i++) {
        float2 ci = float2(rects[i * 5 + 0] + rects[i * 5 + 2] * 0.5, rects[i * 5 + 1] + rects[i * 5 + 3] * 0.5);
        float2 hi = float2(rects[i * 5 + 2], rects[i * 5 + 3]) * 0.5;
        float ri = min(rects[i * 5 + 4], min(hi.x, hi.y));
        float d = sdRoundRect(pos, ci, hi, ri);
        if (d < bestD) { bestD = d; c = ci; h = hi; r = ri; }
    }

    if (bestD >= 0.0) {
        // Between tiles: the backdrop, slightly dimmed and softened.
        half4 s = layer.sample(pos);
        half4 s2 = layer.sample(pos + float2(1.5, 0.0)) + layer.sample(pos - float2(1.5, 0.0))
                 + layer.sample(pos + float2(0.0, 1.5)) + layer.sample(pos - float2(0.0, 1.5));
        half4 soft = mix(s, s2 * 0.25h, half(0.6 * frost));
        return half4(soft.rgb * 0.82h, soft.a);
    }

    // Inside a tile.
    float inset = -bestD;                          // px from the edge
    float band = min(18.0, min(h.x, h.y) * 0.6);   // refraction band width
    float e = 1.0;
    float2 nrm = normalize(float2(
        sdRoundRect(pos + float2(e, 0.0), c, h, r) - sdRoundRect(pos - float2(e, 0.0), c, h, r),
        sdRoundRect(pos + float2(0.0, e), c, h, r) - sdRoundRect(pos - float2(0.0, e), c, h, r)) + 1e-5);

    float t = clamp(1.0 - inset / band, 0.0, 1.0);       // 1 at the edge, 0 inside
    float bend = refraction * pow(t, 2.2) * band * 1.4;   // pull content in from outside the edge
    // Gentle magnification in the middle, like a thick lens.
    float2 lens = (pos - c) * (1.0 - 0.035 * refraction);
    float2 basePos = c + lens + nrm * bend;

    // Chromatic dispersion near the edge.
    float disp = 1.0 + 0.9 * t * refraction;
    float2 off = nrm * disp;

    // Frost: a small disc blur.
    float fr = 1.0 + frost * 4.0;
    half3 acc = half3(0.0);
    half aacc = 0.0h;
    const float2 taps[7] = { float2(0, 0), float2(1, 0), float2(-1, 0), float2(0.5, 0.87),
                             float2(-0.5, 0.87), float2(0.5, -0.87), float2(-0.5, -0.87) };
    for (int i = 0; i < 7; i++) {
        float2 p = basePos + taps[i] * fr;
        half rr = layer.sample(p + off).r;
        half4 gg = layer.sample(p);
        half bb = layer.sample(p - off).b;
        acc += half3(rr, gg.g, bb);
        aacc += gg.a;
    }
    half3 col = acc / 7.0h;
    half a = aacc / 7.0h;

    // Glass body: a touch brighter, like light inside the glass.
    col = mix(col, half3(1.0h), 0.05h);

    // Lit rim: bright on the edges facing the light (top-left), faint opposite.
    float2 lightDir = normalize(float2(-0.6, -0.8));
    float facing = dot(nrm, lightDir);
    float rimLine = 1.0 - smoothstep(0.0, 1.6, inset);
    float rimGlow = pow(t, 3.0);
    float highlight = rimLine * (0.35 + 0.45 * max(facing, 0.0))
                    + rimGlow * 0.22 * max(facing, 0.0)
                    + rimLine * 0.12 * max(-facing, 0.0);
    col += half3(half(highlight));

    return half4(col, max(a, half(0.85)));
}
