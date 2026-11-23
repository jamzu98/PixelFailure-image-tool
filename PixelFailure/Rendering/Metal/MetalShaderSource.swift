import Foundation

/// Metal source for the raster pattern kernels. Compiled at runtime by
/// `MetalCompute` with the system's built-in Metal compiler, so building the
/// app doesn't need Xcode's optional Metal Toolchain download.
nonisolated enum MetalShaderSource {
    static let generators = #"""
#include <metal_stdlib>
using namespace metal;

// Raster pattern generators. Every kernel takes its scalar settings as a
// flat float array (buffer 0), the palette as float4 colors (buffer 1) and
// the seed as a uint (buffer 2). Output is sRGB-encoded RGBA.

// MARK: - Hashing and noise

static uint pf_hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

static uint pf_hash2(int2 p, uint seed) {
    return pf_hash(uint(p.x) * 0x8da6b343u ^ pf_hash(uint(p.y) * 0xd8163841u ^ seed));
}

static float pf_unit(uint h) { return float(h) / 4294967296.0; }

static float2 pf_gradient(int2 p, uint seed) {
    float a = pf_unit(pf_hash2(p, seed)) * 6.2831853;
    return float2(cos(a), sin(a));
}

/// Gradient noise, roughly [-1, 1].
static float pf_gnoise(float2 p, uint seed) {
    int2 i = int2(floor(p));
    float2 f = p - floor(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(pf_gradient(i, seed), f);
    float b = dot(pf_gradient(i + int2(1, 0), seed), f - float2(1, 0));
    float c = dot(pf_gradient(i + int2(0, 1), seed), f - float2(0, 1));
    float d = dot(pf_gradient(i + int2(1, 1), seed), f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.414;
}

/// Worley distances (F1, F2) on a jittered unit grid.
static float2 pf_worley(float2 p, uint seed, float jitter) {
    int2 i = int2(floor(p));
    float f1 = 8.0, f2 = 8.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int2 cell = i + int2(x, y);
            uint h = pf_hash2(cell, seed);
            float2 feature = float2(cell) + 0.5 + (float2(pf_unit(h), pf_unit(pf_hash(h))) - 0.5) * jitter;
            float d = length(feature - p);
            if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
        }
    }
    return float2(f1, f2);
}

/// Fractal noise of the chosen kind: 0 gradient, 1 Worley, 2 ridged.
static float pf_fbm(float2 p, int octaves, int kind, uint seed) {
    float sum = 0.0, amplitude = 1.0, norm = 0.0;
    for (int o = 0; o < octaves; o++) {
        float n;
        if (kind == 1) {
            n = 1.0 - pf_worley(p, seed + uint(o) * 101u, 1.0).x * 1.6;
        } else {
            n = pf_gnoise(p, seed + uint(o) * 101u);
            if (kind == 2) { n = 1.0 - abs(n); n = n * n * 2.0 - 1.0; }
        }
        sum += n * amplitude;
        norm += amplitude;
        amplitude *= 0.5;
        p = p * 2.03 + float2(17.1, 9.3);
    }
    return sum / norm;
}

// MARK: - Palette mapping

/// Maps t in [0, 1] across the palette, optionally posterized into bands.
static float4 pf_palette(float t, constant float4 *palette, int count, float bands) {
    t = clamp(t, 0.0, 1.0);
    if (bands >= 1.5) { t = floor(t * bands) / (bands - 1.0); t = clamp(t, 0.0, 1.0); }
    if (count <= 1) { return palette[0]; }
    float x = t * float(count - 1);
    int i = min(int(floor(x)), count - 2);
    return mix(palette[i], palette[i + 1], x - float(i));
}

static float pf_contrast(float v, float contrast) {
    return clamp((v - 0.5) * contrast + 0.5, 0.0, 1.0);
}

// MARK: - Noise field

// p: 0 width, 1 height, 2 scale, 3 octaves, 4 warp, 5 contrast, 6 kind,
//    7 palette count, 8 bands, 9 drift x, 10 drift y
kernel void pf_noise_field(texture2d<float, access::write> out [[texture(0)]],
                           constant float *p [[buffer(0)]],
                           constant float4 *palette [[buffer(1)]],
                           constant uint &seed [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
    float shortSide = min(p[0], p[1]);
    float2 uv = (float2(gid) + 0.5) / shortSide * p[2] + float2(p[9], p[10]);
    int octaves = int(p[3]);
    int kind = int(p[6]);
    if (p[4] > 0.0) {
        float2 q = float2(pf_fbm(uv + float2(5.2, 1.3), 3, 0, seed ^ 0xA511u),
                          pf_fbm(uv + float2(1.7, 9.2), 3, 0, seed ^ 0x5A22u));
        uv += q * p[4];
    }
    float v = pf_fbm(uv, octaves, kind, seed) * 0.5 + 0.5;
    v = pf_contrast(v, p[5]);
    out.write(pf_palette(v, palette, int(p[7]), p[8]), gid);
}

// MARK: - Voronoi

// p: 0 width, 1 height, 2 cells across the short side, 3 edge width,
//    4 jitter, 5 style (0 cells, 1 edges, 2 cells + edges, 3 distance),
//    6 palette count, 7 bands
kernel void pf_voronoi(texture2d<float, access::write> out [[texture(0)]],
                       constant float *p [[buffer(0)]],
                       constant float4 *palette [[buffer(1)]],
                       constant uint &seed [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
    float shortSide = min(p[0], p[1]);
    float2 uv = (float2(gid) + 0.5) / shortSide * p[2];
    float jitter = p[4];
    int2 i = int2(floor(uv));
    float f1 = 8.0, f2 = 8.0;
    int2 nearest = i;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int2 cell = i + int2(x, y);
            uint h = pf_hash2(cell, seed);
            float2 feature = float2(cell) + 0.5 + (float2(pf_unit(h), pf_unit(pf_hash(h))) - 0.5) * jitter;
            float d = length(feature - uv);
            if (d < f1) { f2 = f1; f1 = d; nearest = cell; } else if (d < f2) { f2 = d; }
        }
    }
    int count = int(p[6]);
    int style = int(p[5]);
    float edge = 1.0 - smoothstep(p[3] * 0.5, p[3] * 0.5 + 0.02, f2 - f1);
    float4 cellColor = palette[pf_hash2(nearest, seed ^ 0x77u) % uint(max(count, 1))];
    float4 edgeColor = palette[count > 1 ? count - 1 : 0] * float4(0.15, 0.15, 0.15, 1.0);
    float4 color;
    if (style == 1) {
        color = mix(palette[0], palette[count > 1 ? count - 1 : 0], edge);
    } else if (style == 3) {
        color = pf_palette(clamp(f1 * 1.4, 0.0, 1.0), palette, count, p[7]);
    } else {
        color = cellColor;
        if (style == 2) { color = mix(color, edgeColor, edge); }
    }
    color.a = 1.0;
    out.write(color, gid);
}

// MARK: - Plasma

// p: 0 width, 1 height, 2 scale, 3 waves, 4 phase, 5 contrast,
//    6 palette count, 7 bands
kernel void pf_plasma(texture2d<float, access::write> out [[texture(0)]],
                      constant float *p [[buffer(0)]],
                      constant float4 *palette [[buffer(1)]],
                      constant uint &seed [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
    float shortSide = min(p[0], p[1]);
    float2 uv = (float2(gid) + 0.5) / shortSide * p[2];
    int waves = int(p[3]);
    float sum = 0.0;
    for (int w = 0; w < waves; w++) {
        uint h = pf_hash(seed + uint(w) * 7919u);
        float angle = pf_unit(h) * 6.2831853;
        float frequency = 0.6 + pf_unit(pf_hash(h)) * 2.4;
        float2 dir = float2(cos(angle), sin(angle));
        float phase = pf_unit(pf_hash(h ^ 0x9e37u)) * 6.2831853 + p[4] * (1.0 + float(w) * 0.37);
        if (w % 3 == 2) {
            // Radial ripples around a seeded center.
            float2 c = float2(pf_unit(pf_hash(h + 1u)), pf_unit(pf_hash(h + 2u))) * p[2];
            sum += sin(length(uv - c) * frequency * 3.0 + phase);
        } else {
            sum += sin(dot(uv, dir) * frequency * 3.0 + phase);
        }
    }
    float v = sum / float(max(waves, 1)) * 0.5 + 0.5;
    v = pf_contrast(v, p[5]);
    float4 color = pf_palette(v, palette, int(p[6]), p[7]);
    color.a = 1.0;
    out.write(color, gid);
}

// MARK: - Reaction–diffusion (Gray–Scott)

// p: 0 width, 1 height, 2 spot count, 3 spot radius (in pixels)
kernel void pf_rd_init(texture2d<float, access::write> out [[texture(0)]],
                       constant float *p [[buffer(0)]],
                       constant uint &seed [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
    float2 pos = float2(gid);
    float v = 0.0;
    int spots = int(p[2]);
    for (int s = 0; s < spots; s++) {
        uint h = pf_hash(seed + uint(s) * 2654435761u);
        float2 c = float2(pf_unit(h), pf_unit(pf_hash(h))) * float2(p[0], p[1]);
        float radius = p[3] * (0.5 + pf_unit(pf_hash(h ^ 0x51u)));
        if (length(pos - c) < radius) { v = 1.0; }
    }
    // A little seeded noise breaks perfect symmetry.
    v = max(v, pf_unit(pf_hash2(int2(gid), seed)) < 0.0015 ? 1.0 : 0.0);
    // Gray–Scott seeds: U = 1 everywhere, spots start at U = 0.5, V = 0.25.
    out.write(v > 0.0 ? float4(0.5, 0.25, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0), gid);
}

// p: 0 width, 1 height, 2 feed, 3 kill, 4 diffusion U, 5 diffusion V
kernel void pf_rd_step(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float *p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int w = int(p[0]), h = int(p[1]);
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    int2 g = int2(gid);
    float2 center = src.read(gid).rg;
    float2 laplacian = -center;
    const int2 edges[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
    const int2 corners[4] = { int2(1, 1), int2(-1, 1), int2(1, -1), int2(-1, -1) };
    for (int k = 0; k < 4; k++) {
        int2 e = (g + edges[k] + int2(w, h)) % int2(w, h);
        int2 c = (g + corners[k] + int2(w, h)) % int2(w, h);
        laplacian += src.read(uint2(e)).rg * 0.2 + src.read(uint2(c)).rg * 0.05;
    }
    float u = center.r, v = center.g;
    float uvv = u * v * v;
    float feed = p[2], kill = p[3];
    float nu = u + (p[4] * laplacian.r - uvv + feed * (1.0 - u));
    float nv = v + (p[5] * laplacian.g + uvv - (kill + feed) * v);
    dst.write(float4(clamp(nu, 0.0, 1.0), clamp(nv, 0.0, 1.0), 0.0, 1.0), gid);
}

// p: 0 width, 1 height, 2 contrast, 3 palette count, 4 bands
kernel void pf_rd_color(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> out [[texture(1)]],
                        constant float *p [[buffer(0)]],
                        constant float4 *palette [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
    float2 uv = src.read(gid).rg;
    float t = clamp(uv.g * 2.6, 0.0, 1.0);
    t = pf_contrast(t, p[2]);
    float4 color = pf_palette(t, palette, int(p[3]), p[4]);
    color.a = 1.0;
    out.write(color, gid);
}
"""#

    /// Glitch effect kernels. They reuse the hash and noise helpers above,
    /// so this source is always appended after `generators`.
    static let glitch = #"""
// MARK: - Glitch effects
//
// Each kernel reads `src` (the input region) and writes `dst` (one output
// tile). p[0..7]: src origin x/y, src width/height, dst origin x/y, image
// width/height. Positions are absolute pixels, so tiles join seamlessly.

static float4 pf_read(texture2d<float, access::read> src, constant float *p, float2 pos) {
    float2 local = pos - float2(p[0], p[1]);
    int2 i = int2(clamp(local, float2(0.0), float2(p[2] - 1.0, p[3] - 1.0)));
    return src.read(uint2(i));
}

// p[8] block size px, 9 amount, 10 max shift px, 11 smear, 12 bleed px
kernel void pf_datamosh(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *p [[buffer(0)]],
                        constant uint &seed [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 pos = float2(p[4], p[5]) + float2(gid) + 0.5;
    float block = max(p[8], 1.0);
    int2 cell = int2(floor(pos / block));
    uint h = pf_hash2(cell, seed);
    if (pf_unit(h) >= p[9]) { dst.write(pf_read(src, p, pos), gid); return; }
    // Displace whole blocks; rows of blocks move together for a smeared look.
    uint rowHash = pf_hash2(int2(0, cell.y), seed ^ 0x1234u);
    float shift = (pf_unit(rowHash) * 2.0 - 1.0) * p[10] + (pf_unit(pf_hash(h)) * 2.0 - 1.0) * block;
    float2 from = pos - float2(shift, (pf_unit(pf_hash(h ^ 7u)) - 0.5) * block * 0.5);
    if (pf_unit(pf_hash(h ^ 0x33u)) < p[11]) { from.y = floor(pos.y / block) * block + 0.5; }
    float4 c = pf_read(src, p, from);
    if (p[12] > 0.0) {
        c.r = pf_read(src, p, from + float2(p[12], 0.0)).r;
        c.b = pf_read(src, p, from - float2(p[12], 0.0)).b;
    }
    dst.write(c, gid);
}

// p[8] amount px, 9 frequency, 10 jitter, 11 mode (0 R/B, 1 RGB)
kernel void pf_noise_shift(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant float *p [[buffer(0)]],
                           constant uint &seed [[buffer(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 pos = float2(p[4], p[5]) + float2(gid) + 0.5;
    float y = pos.y / max(p[7], 1.0);
    float n = pf_gnoise(float2(y * p[9], 0.37), seed);
    float bandCount = max(p[9] * 4.0, 1.0);
    uint band = pf_hash2(int2(int(floor(y * bandCount)), 0), seed ^ 0x55u);
    if (pf_unit(band) < p[10]) { n += (pf_unit(pf_hash(band)) * 2.0 - 1.0) * 2.0; }
    float offset = n * p[8];
    float4 c = pf_read(src, p, pos);
    c.r = pf_read(src, p, pos + float2(offset, 0.0)).r;
    c.b = pf_read(src, p, pos - float2(offset * 0.8, 0.0)).b;
    if (p[11] > 0.5) { c.g = pf_read(src, p, pos + float2(offset * 0.45, 0.0)).g; }
    dst.write(c, gid);
}

constant float pf_bayer8[64] = {
     0, 32,  8, 40,  2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37, 63, 31, 55, 23, 61, 29, 53, 21 };

// p[8] method (0 Bayer 4, 1 Bayer 8, 2 blue noise), 9 cell px, 10 spread,
// 11 palette count. Palette (buffer 1) is in linear light.
kernel void pf_dither(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *p [[buffer(0)]],
                      constant float4 *palette [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 pos = float2(p[4], p[5]) + float2(gid) + 0.5;
    float cell = max(p[9], 1.0);
    int2 index = int2(floor(pos / cell));
    float4 c = pf_read(src, p, (float2(index) + 0.5) * cell);
    float t;
    int method = int(p[8]);
    if (method == 0) {
        int2 m = index & 3;
        t = pf_bayer8[(m.y * 2) * 8 + m.x * 2] / 64.0;
    } else if (method == 1) {
        int2 m = index & 7;
        t = pf_bayer8[m.y * 8 + m.x] / 64.0;
    } else {
        // Interleaved gradient noise: cheap, evenly spread (blue-ish) noise.
        t = fract(52.9829189 * fract(0.06711056 * float(index.x) + 0.00583715 * float(index.y)));
    }
    int count = max(int(p[11]), 1);
    float3 target = c.rgb + (t - 0.5) * p[10] * (1.0 / float(max(count - 1, 1)) + 0.25);
    float best = 1e9;
    float3 chosen = palette[0].rgb;
    for (int k = 0; k < count; k++) {
        float3 d = target - palette[k].rgb;
        float dist = dot(d, d);
        if (dist < best) { best = dist; chosen = palette[k].rgb; }
    }
    dst.write(float4(chosen, c.a), gid);
}
"""#
}
