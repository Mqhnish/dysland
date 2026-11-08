//
//  LiquidShaders.metal
//  boringNotch
//
//  GPU shaders for the notch's liquid visuals.
//
//  ferrofluid: the music visualiser. A neat row of glossy liquid beads that
//  swell with their frequency band and merge with their neighbours.
//
//  liquidGlass: refraction for the custom glass. Bends the captured backdrop
//  at the edges of each glass tile, with slight chromatic dispersion, frost
//  inside the tiles and a lit rim.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Liquid visualiser

// A tidy row of liquid beads, one per lane, each breathing with its own
// frequency band, so it reads like an equaliser made of liquid. Neighbours
// bridge and merge when they swell together; one small droplet wanders along
// the row and melts into whichever bead it reaches. Colour runs as a smooth
// gradient through the palette from left to right (no muddy per-blob mixing).

constant int BEADS = 5;

float3 paletteAt(float x, device const float *cols, int n) {
    if (n <= 1) return float3(cols[0], cols[1], cols[2]);
    float f = clamp(x, 0.0, 1.0) * float(n - 1);
    int i = min(int(floor(f)), n - 2);
    float t = smoothstep(0.0, 1.0, f - float(i));
    float3 a = float3(cols[i * 4 + 0], cols[i * 4 + 1], cols[i * 4 + 2]);
    float3 b = float3(cols[(i + 1) * 4 + 0], cols[(i + 1) * 4 + 1], cols[(i + 1) * 4 + 2]);
    return mix(a, b, t);
}

[[ stitchable ]] half4 ferrofluid(float2 pos,
                                  float2 size,
                                  float time,
                                  float4 bands,      // bass, low-mid, mid, high (0...1)
                                  float beat,        // 0...1 envelope
                                  float spikiness,   // user setting, 0...1
                                  device const float *cols, int colCount)
{
    int nColors = max(colCount / 4, 1);
    float lane = size.x / float(BEADS);
    float midY = size.y * 0.56;

    // Which band drives each bead: bass in the middle, highs at the edges.
    float drive[BEADS] = { bands.w, bands.z, bands.x, bands.y, mix(bands.w, bands.z, 0.5) };

    float field = 0.0;
    float2 grad = float2(0.0);
    float2 domCenter = float2(0.0);
    float domContrib = 0.0;

    for (int i = 0; i < BEADS; i++) {
        float fi = float(i);
        // Stay near the lane centre; just a gentle sway and bob.
        float cx = (fi + 0.5) * lane + lane * 0.16 * sin(time * (0.23 + 0.04 * fi) + fi * 1.9);
        float cy = midY + size.y * 0.07 * sin(time * (0.31 + 0.05 * fi) + fi * 2.4)
                 - beat * size.y * 0.05 * (i == 2 ? 1.0 : 0.4);
        float breathe = 0.5 + 0.5 * sin(time * 0.6 + fi * 1.4);
        float r = size.y * (0.105 + 0.018 * breathe + 0.13 * drive[i] + 0.035 * beat);

        float2 d = pos - float2(cx, cy);
        float d2 = dot(d, d) + 1.0;
        float c = (r * r) / d2;
        field += c;
        grad += -2.0 * r * r * d / (d2 * d2);
        if (c > domContrib) { domContrib = c; domCenter = float2(cx, cy); }
    }

    // The wandering droplet: glides slowly end to end along the row.
    {
        float u = 0.5 + 0.5 * sin(time * 0.11);
        float cx = mix(lane * 0.3, size.x - lane * 0.3, u);
        float cy = midY - size.y * 0.2 + size.y * 0.06 * sin(time * 0.9);
        float r = size.y * (0.06 + 0.02 * bands.y);
        float2 d = pos - float2(cx, cy);
        float d2 = dot(d, d) + 1.0;
        field += (r * r) / d2;
        grad += -2.0 * r * r * d / (d2 * d2);
    }

    // Optional ferrofluid spikes: few, short, only on strong beats/highs.
    if (spikiness > 0.01) {
        float2 rel = pos - domCenter;
        float theta = atan2(rel.y, rel.x);
        float ridge = pow(abs(sin(theta * 6.0 + time * 0.5)), 16.0);
        float amount = spikiness * (0.6 * bands.w + 0.8 * beat);
        float near = smoothstep(0.45, 0.95, field) * (1.0 - smoothstep(1.0, 1.4, field));
        field *= 1.0 + ridge * amount * near * 0.6;
    }

    // Crisp anti-aliased edge via distance-to-surface in pixels.
    float gl = max(length(grad), 1e-4);
    float edgePx = (field - 1.0) / gl;
    float alpha = clamp(edgePx * 0.9 + 0.5, 0.0, 1.0);

    float3 base = paletteAt(pos.x / size.x, cols, nColors);

    // Smooth dome normal.
    float k = size.y * 0.22;
    float3 n = normalize(float3(-grad.x * k, -grad.y * k, 1.0));
    float3 L = normalize(float3(-0.35, -0.75, 0.55));
    float diff = clamp(dot(n, L), 0.0, 1.0);
    float3 R = reflect(-L, n);
    float spec = pow(max(R.z, 0.0), 42.0);
    float rim = pow(1.0 - n.z, 3.0);

    // Glossy but restrained: a vertical light falloff, a soft diffuse term,
    // one clean highlight, and a thin luminous rim.
    float3 color = base * (0.55 + 0.45 * diff);
    color = mix(color, base * 0.55, clamp(n.y * 0.6, 0.0, 0.6));   // shade the underside
    color += mix(base, float3(1.0), 0.6) * rim * 0.45;
    color += float3(1.0) * spec * (0.55 + 0.35 * beat);

    // Faint glow just outside the surface.
    float halo = smoothstep(0.35, 1.0, field) * (1.0 - alpha) * (0.18 + 0.2 * bands.x);
    float3 outColor = color * alpha + base * halo;
    float outAlpha = alpha * 0.92 + halo;
    return half4(half3(outColor), half(clamp(outAlpha, 0.0, 1.0)));
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
