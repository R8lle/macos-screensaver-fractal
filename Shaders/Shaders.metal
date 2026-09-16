#include <metal_stdlib>
using namespace metal;

// Perturbation: CPU double orbit stored as DS float4 (zx_hi, zx_lo, zy_hi, zy_lo).
// GPU iterates a float delta. That holds to ~1e-10 instead of ~1e-5.

struct Uniforms {
    float2 resolution;
    float scale;
    float aspect;
    float2 param;
    float2 jitter;
    uint palette;
    uint maxIter;
    uint refLen;
    uint formula;
    float fade;
    float pad;
};

struct VSOut {
    float4 position [[position]];
};

vertex VSOut fractal_vs(uint vid [[vertex_id]]) {
    float2 p;
    if (vid == 0) p = float2(-1.0, -1.0);
    else if (vid == 1) p = float2(3.0, -1.0);
    else p = float2(-1.0, 3.0);
    VSOut out;
    out.position = float4(p, 0.0, 1.0);
    return out;
}

static float2 cmul(float2 a, float2 b) {
    return float2(fma(a.x, b.x, -a.y * b.y), fma(a.x, b.y, a.y * b.x));
}

static float3 paletteColor(uint palette, float mu) {
    float t = fract(mu * 0.028);
    float3 a, b, c, d;
    switch (palette) {
        case 1:
            a = float3(0.05, 0.04, 0.12);
            b = float3(0.25, 0.35, 0.85);
            c = float3(0.95, 0.85, 0.45);
            d = float3(1.00, 0.98, 0.92);
            break;
        case 2:
            a = float3(0.02, 0.00, 0.00);
            b = float3(0.55, 0.05, 0.00);
            c = float3(0.95, 0.35, 0.02);
            d = float3(1.00, 0.92, 0.45);
            break;
        case 3:
            a = float3(0.01, 0.04, 0.10);
            b = float3(0.05, 0.28, 0.55);
            c = float3(0.25, 0.75, 0.90);
            d = float3(0.92, 0.98, 1.00);
            break;
        case 4:
            a = float3(0.04, 0.02, 0.00);
            b = float3(0.45, 0.18, 0.02);
            c = float3(0.92, 0.62, 0.12);
            d = float3(1.00, 0.94, 0.70);
            break;
        case 5:
            a = float3(0.03, 0.00, 0.06);
            b = float3(0.28, 0.05, 0.45);
            c = float3(0.72, 0.22, 0.82);
            d = float3(0.95, 0.82, 1.00);
            break;
        case 6:
            a = float3(0.02, 0.02, 0.025);
            b = float3(0.18, 0.19, 0.22);
            c = float3(0.62, 0.64, 0.68);
            d = float3(0.94, 0.95, 0.97);
            break;
        default:
            a = float3(0.02, 0.03, 0.05);
            b = float3(0.04, 0.28, 0.38);
            c = float3(0.95, 0.62, 0.18);
            d = float3(0.70, 0.95, 1.00);
            break;
    }
    float s = smoothstep(0.0, 1.0, t);
    float3 lo = mix(a, b, clamp(s * 2.0, 0.0, 1.0));
    float3 hi = mix(c, d, clamp(s * 2.0 - 1.0, 0.0, 1.0));
    return mix(lo, hi, smoothstep(0.35, 0.85, s));
}

static float3 sampleFractal(constant Uniforms &u, constant float4 *ref, float2 pixel) {
    float2 ndc;
    ndc.x = 2.0 * pixel.x / max(u.resolution.x, 1.0) - 1.0;
    ndc.y = 1.0 - 2.0 * pixel.y / max(u.resolution.y, 1.0);
    float2 dc = float2(ndc.x * u.aspect, ndc.y) * u.scale;
    const uint julia = 1u;
    const uint ship = 2u;
    const uint tricorn = 3u;
    const uint shipJulia = 4u;
    bool juliaLike = (u.formula == julia) || (u.formula == shipJulia);
    float2 delta = juliaLike ? dc : float2(0.0);
    float2 addC = juliaLike ? float2(0.0) : dc;

    uint i = 0;
    float mag = 0.0;
    uint limit = min(min(u.refLen, u.maxIter), 1024u);
    for (; i < limit; i++) {
        float4 p = ref[i];
        float2 Zhi = float2(p.x, p.z);
        float2 Zlo = float2(p.y, p.w);
        float2 z = Zhi + delta;
        mag = dot(z, z);
        if (mag > 256.0) break;

        if (u.formula == ship || u.formula == shipJulia) {
            float sx = Zhi.x < 0.0 ? -1.0 : 1.0;
            float sy = Zhi.y < 0.0 ? -1.0 : 1.0;
            float2 Zf = float2(abs(Zhi.x), abs(Zhi.y));
            float2 dlt = float2(sx * delta.x, sy * delta.y);
            delta = 2.0 * cmul(Zf, dlt) + cmul(dlt, dlt) + addC;
        } else if (u.formula == tricorn) {
            // conj(Z+δ)^2 − conj(Z)^2 = 2 conj(Z) conj(δ) + conj(δ)^2
            float2 Zh = float2(Zhi.x, -Zhi.y);
            float2 Zl = float2(Zlo.x, -Zlo.y);
            float2 dlt = float2(delta.x, -delta.y);
            delta = 2.0 * (cmul(Zh, dlt) + cmul(Zl, dlt)) + cmul(dlt, dlt) + addC;
        } else {
            delta = 2.0 * (cmul(Zhi, delta) + cmul(Zlo, delta)) + cmul(delta, delta) + addC;
        }
    }

    if (i >= limit) return float3(0.0);
    float logZn = log(max(mag, 1e-12)) * 0.5;
    float mu = float(i) + 1.0 - log2(max(logZn, 1e-6));
    return paletteColor(u.palette, mu);
}

static float3 clipAABB(float3 hist, float3 aabbMin, float3 aabbMax) {
    float3 center = 0.5 * (aabbMin + aabbMax);
    float3 extents = 0.5 * (aabbMax - aabbMin) + float3(1e-4);
    float3 v = hist - center;
    float3 t = abs(v / extents);
    float m = max(max(t.x, t.y), t.z);
    if (m > 1.0) {
        return center + v / m;
    }
    return hist;
}

fragment float4 fractal_fs(VSOut in [[stage_in]],
                         constant Uniforms &u [[buffer(0)]],
                         constant float4 *ref [[buffer(1)]]) {
    // 2×2 of a 4×4 pixel lattice. `jitter` selects the 4-frame phase so TAA
    // accumulates all 16 locations without paying 4×4 in one frame.
    float2 o = in.position.xy + float2(-0.375, -0.375) + u.jitter;
    float3 acc = float3(0.0);
    acc += sampleFractal(u, ref, o);
    acc += sampleFractal(u, ref, o + float2(0.5, 0.0));
    acc += sampleFractal(u, ref, o + float2(0.0, 0.5));
    acc += sampleFractal(u, ref, o + float2(0.5, 0.5));
    return float4(acc * 0.25 * u.fade, 1.0);
}

struct TAAUniforms {
    float ratio;
    float blend;
    float valid;
    float keep;
};

struct BlitOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitOut blit_vs(uint vid [[vertex_id]]) {
    float2 p;
    if (vid == 0) p = float2(-1.0, -1.0);
    else if (vid == 1) p = float2(3.0, -1.0);
    else p = float2(-1.0, 3.0);
    BlitOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

fragment float4 taa_fs(BlitOut in [[stage_in]],
                       constant TAAUniforms &u [[buffer(0)]],
                       texture2d<float> fresh [[texture(0)]],
                       texture2d<float> hist [[texture(1)]],
                       sampler smp [[sampler(0)]]) {
    float4 curr = fresh.sample(smp, in.uv);
    if (u.valid < 0.5) {
        return curr;
    }

    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    float2 ndcPrev = ndc * u.ratio;
    float2 uvPrev = float2(ndcPrev.x * 0.5 + 0.5, 0.5 - ndcPrev.y * 0.5);
    if (uvPrev.x < 0.0 || uvPrev.x > 1.0 || uvPrev.y < 0.0 || uvPrev.y > 1.0) {
        return curr;
    }

    float3 history = hist.sample(smp, uvPrev).rgb;
    float3 cmin = curr.rgb;
    float3 cmax = curr.rgb;
    float2 texel = 1.0 / float2(max(float(fresh.get_width()), 1.0),
                                max(float(fresh.get_height()), 1.0));
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float3 n = fresh.sample(smp, in.uv + float2(x, y) * texel).rgb;
            cmin = min(cmin, n);
            cmax = max(cmax, n);
        }
    }
    float3 range = max(cmax - cmin, float3(1e-4));
    float3 clipped = clipAABB(history, cmin - range * 0.7, cmax + range * 0.7);
    float edge = min(min(in.uv.x, 1.0 - in.uv.x), min(in.uv.y, 1.0 - in.uv.y));
    float clampW = smoothstep(0.0, 0.05, edge);
    history = mix(history, mix(clipped, history, 0.55 * u.keep), clampW);
    float contrast = saturate(dot(range, float3(0.3, 0.6, 0.1)) * 3.5);
    float extra = 0.12 * u.keep;
    float blend = mix(u.blend, min(u.blend + extra, 0.88), contrast);
    return float4(mix(curr.rgb, history, blend), 1.0);
}

fragment float4 blit_fs(BlitOut in [[stage_in]],
                        texture2d<float> src [[texture(0)]],
                        sampler smp [[sampler(0)]]) {
    return src.sample(smp, in.uv);
}

// HUD overlay: axis-aligned textured quad (rect in NDC: x0,y0,x1,y1).
struct HudOut {
    float4 position [[position]];
    float2 uv;
};

vertex HudOut hud_vs(uint vid [[vertex_id]],
                     constant float4 &rect [[buffer(0)]]) {
    float2 corners[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };
    float2 c = corners[vid];
    float2 pos = float2(mix(rect.x, rect.z, c.x), mix(rect.y, rect.w, c.y));
    float2 uvs[6] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)
    };
    HudOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 hud_fs(HudOut in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}
