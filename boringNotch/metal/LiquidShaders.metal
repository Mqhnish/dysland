//
//  LiquidShaders.metal
//  boringNotch
//
//  GPU shaders for the notch's liquid visuals.
//
//  ferrofluid: the music visualiser. A metaball field of 7 blobs, each on its
//  own lane across the panel (so they meet and split instead of clumping),
//  shaded like glossy ferrofluid: dome normals from the field gradient, a
//  sharp specular highlight, a coloured reflective rim, a soft halo, and
//  spikes that grow out of the surface with the high frequencies / beats.
//
//  liquidGlass: refraction for the custom glass. Bends the captured backdrop
//  at the edges of each glass tile, with slight chromatic dispersion, frost
//  inside the tiles and a lit rim.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Ferrofluid visualiser

constant int BLOBS = 7;

[[ stitchable ]] half4 ferrofluid(float2 pos,
                                  float2 size,
                                  float time,
                                  float4 bands,      // bass, low-mid, mid, high (0...1)
                                  float beat,        // 0...1 envelope
                                  float spikiness,   // user setting, 0...1
                                  device const float *cols, int colCount)
{
    int nColors = max(colCount / 4, 1);
    float field = 0.0;
    float2 grad = float2(0.0);
    float3 colorSum = float3(0.0);
    float weightSum = 0.0;
    float best = 0.0;
    float2 bestCenter = float2(0.0);
    float bestIndex = 0.0;

    float lane = size.x / float(BLOBS);

    for (int i = 0; i < BLOBS; i++) {
        float fi = float(i);
        // Own lane, wide swing into the neighbours' lanes, plus a slower drift.
        float cx = (fi + 0.5) * lane
                 + lane * 0.95 * sin(time * (0.21 + 0.06 * fi) + fi * 1.7)
                 + lane * 0.35 * sin(time * 0.57 + fi * 2.3);
        float cy = size.y * (0.52 + 0.27 * sin(time * (0.29 + 0.05 * fi) + fi * 2.9));
        // Beat kick: a quick hop away from the centre line.
        cy += (fmod(fi, 2.0) < 1.0 ? -1.0 : 1.0) * beat * size.y * 0.06;

        float band = bands[i % 4];
        float r = size.y * (0.15 + 0.035 * sin(time * 0.7 + fi * 1.3))
                * (1.0 + 0.65 * band + 0.3 * beat);

        float2 d = pos - float2(cx, cy);
        float d2 = dot(d, d) + 1.0;
        float contrib = (r * r) / d2;
        field += contrib;
        grad += -2.0 * r * r * d / (d2 * d2);

        int ci = i % nColors;
        float3 c = float3(cols[ci * 4 + 0], cols[ci * 4 + 1], cols[ci * 4 + 2]);
        colorSum += c * contrib * contrib;
        weightSum += contrib * contrib;

        if (contrib > best) { best = contrib; bestCenter = float2(cx, cy); bestIndex = fi; }
    }

    // Ferrofluid spikes: radial ridges around the dominant blob, only near
    // the surface, growing with the highs and the beat.
    float2 rel = pos - bestCenter;
    float theta = atan2(rel.y, rel.x);
    float ridge = pow(abs(sin(theta * 7.0 + time * 0.9 + bestIndex * 1.3)), 12.0) * 0.65
                + pow(abs(sin(theta * 13.0 - time * 1.3 + bestIndex)), 20.0) * 0.35;
    float spikeAmount = spikiness * (0.12 + 0.9 * bands.w + 0.9 * beat);
    float nearSurface = smoothstep(0.3, 0.9, field) * (1.0 - smoothstep(1.05, 1.7, field));
    float f = field * (1.0 + ridge * spikeAmount * nearSurface);

    // Anti-aliased edge: distance to the surface in pixels via the gradient.
    float gl = max(length(grad), 1e-4);
    float edgePx = (f - 1.0) / gl;
    float alpha = clamp(edgePx + 0.5, 0.0, 1.0);

    float3 base = weightSum > 0.0 ? colorSum / weightSum : float3(0.5);

    // Dome normal: steep at the rim, flat on top.
    float k = size.y * 0.32;
    float3 n = normalize(float3(-grad.x * k, -grad.y * k, 1.0));
    float3 L = normalize(float3(-0.45, -0.7, 0.6));       // light from top-left
    float diff = max(dot(n, L), 0.0);
    float3 R = reflect(-L, n);
    float spec = pow(max(R.z, 0.0), 60.0);
    float specSoft = pow(max(R.z, 0.0), 10.0);
    float fresnel = pow(1.0 - n.z, 2.2);

    // Fake environment: brighter tint of the colour from above, dark below.
    float3 envTop = mix(base, float3(1.0), 0.45);
    float3 envBottom = base * 0.18;
    float3 env = mix(envBottom, envTop, clamp(0.5 - n.y * 0.6, 0.0, 1.0));

    float3 color = base * 0.28
                 + base * diff * 0.42
                 + env * fresnel * 0.75
                 + float3(1.0) * spec * (0.85 + 0.5 * beat)
                 + base * specSoft * 0.25;

    // Soft luminous halo around the liquid.
    float halo = smoothstep(0.22, 1.0, field) * (1.0 - alpha) * (0.28 + 0.25 * bands.x);
    float3 outColor = color * alpha + base * halo;
    float outAlpha = alpha + halo;
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
