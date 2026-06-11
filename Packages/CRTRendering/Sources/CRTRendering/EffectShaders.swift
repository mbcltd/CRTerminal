/// CRT effect chain MSL, compiled at runtime alongside the cell shaders
/// (see Shaders.swift for why runtime compilation).
///
/// Stages, per ARCHITECTURE.md: persistence (phosphor decay) → bloom
/// (threshold/downsample/separable blur) → composite (curvature, corner
/// rounding, mask, scanlines, convergence, noise, hum bar, jitter,
/// vignette, degauss, procedural bezel).
let effectShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct CRTUniforms {
    float2 viewport;      // output size, device px
    float2 screenOrigin;  // normalized inset of the screen inside the bezel
    float2 screenSize;
    float time;
    float degaussPhase;   // 0..1 while animating, >= 1 when inactive
    float curvature;
    float cornerRadius;
    float vignette;
    float maskType;       // 0 none, 1 aperture, 2 slot, 3 shadow
    float maskPitchPx;
    float maskStrength;
    float scanLines;
    float scanStrength;
    float beamWidth;
    float bloomStrength;
    float noise;
    float humBar;
    float jitter;
    float convergencePx;
    float aberration;
    float monochrome;
    float3 tint;
    float3 bezelColor;
    float bezelPx;
};

struct FSQOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle; uv (0,0) is the top-left, matching the cell pass.
vertex FSQOut fsq_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    FSQOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    return out;
}

// --- Persistence -----------------------------------------------------------

struct PersistenceUniforms {
    float decay; // exp(-dt/tau) for this frame; 0 resets history
};

fragment float4 persistence_fragment(FSQOut in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     texture2d<float> prev [[texture(1)]],
                                     constant PersistenceUniforms &u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float4 c = src.sample(s, in.uv);
    float4 p = prev.sample(s, in.uv) * u.decay;
    return max(c, p); // excited phosphor outshines the decaying trace
}

// --- Bloom -----------------------------------------------------------------

struct BloomExtractUniforms {
    float threshold;
};

fragment float4 bloom_extract_fragment(FSQOut in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       constant BloomExtractUniforms &u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 c = src.sample(s, in.uv).rgb;
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    float k = max(luma - u.threshold, 0.0) / max(luma, 1e-4);
    return float4(c * k, 1.0);
}

struct BlurUniforms {
    float2 step; // one texel in the blur direction, normalized
    float sigma; // in taps
};

fragment float4 blur_fragment(FSQOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant BlurUniforms &u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float sigma = max(u.sigma, 0.001);
    float3 sum = float3(0.0);
    float weightSum = 0.0;
    for (int i = -6; i <= 6; i++) {
        float w = exp(-0.5 * float(i * i) / (sigma * sigma));
        sum += src.sample(s, in.uv + u.step * float(i)).rgb * w;
        weightSum += w;
    }
    return float4(sum / weightSum, 1.0);
}

// --- Composite ---------------------------------------------------------------

static float crt_hash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// Rotate color about the luminance axis (cheap hue shift for degauss).
static float3 crt_hue_rotate(float3 c, float a) {
    const float3 k = float3(0.57735);
    float ca = cos(a);
    return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}

// Signed distance to a rounded rect, c in [-1,1], negative inside.
static float crt_rounded_dist(float2 c, float radius) {
    float2 q = abs(c) - (1.0 - radius);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

fragment float4 crt_composite(FSQOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              texture2d<float> bloom [[texture(1)]],
                              constant CRTUniforms &u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float2 suv = (uv - u.screenOrigin) / u.screenSize;
    float2 c = suv * 2.0 - 1.0;

    // Degauss: an electromagnetic wobble (swirl + breathing ripple) that
    // rings down over the animation, strongest at the tube edges.
    float degaussEnv = 0.0;
    if (u.degaussPhase < 1.0) {
        float p = max(u.degaussPhase, 0.0);
        degaussEnv = exp(-3.5 * p) * (1.0 - p);
        float r = length(c);
        float swirl = degaussEnv * 0.30 * sin(34.0 * p - r * 6.0) * (0.25 + r);
        float ca = cos(swirl), sa = sin(swirl);
        c = float2x2(ca, -sa, sa, ca) * c;
        c *= 1.0 + degaussEnv * 0.05 * sin(40.0 * p - r * 9.0);
    }

    // Barrel distortion (curvature of the glass).
    float r2 = dot(c, c);
    c *= 1.0 + u.curvature * r2;

    // Rounded screen cutoff.
    float dist = crt_rounded_dist(c, max(u.cornerRadius, 0.001));
    float screenPx = min(u.viewport.x * u.screenSize.x, u.viewport.y * u.screenSize.y);
    float edgeAA = 3.0 / max(screenPx, 1.0);
    float screenMask = 1.0 - smoothstep(-edgeAA, edgeAA, dist);

    suv = c * 0.5 + 0.5;
    float2 sampleUV = suv;

    // Interlace-style horizontal jitter, per scan line per frame.
    if (u.jitter > 0.0 && u.scanLines > 0.0) {
        float line = floor(suv.y * u.scanLines);
        float j = crt_hash(float2(line, floor(u.time * 60.0))) - 0.5;
        sampleUV.x += j * u.jitter / u.scanLines;
    }

    // Convergence error + radial chromatic aberration: R and B land
    // either side of where the beam was aimed.
    float offPx = u.convergencePx + u.aberration * r2 * 2.0;
    float3 col;
    if (offPx > 1e-3) {
        float2 off = float2(offPx / max(u.viewport.x * u.screenSize.x, 1.0), 0.0);
        col = float3(src.sample(s, sampleUV + off).r,
                     src.sample(s, sampleUV).g,
                     src.sample(s, sampleUV - off).b);
    } else {
        col = src.sample(s, sampleUV).rgb;
    }
    col += bloom.sample(s, sampleUV).rgb * u.bloomStrength;

    // Monochrome tube: everything becomes phosphor-colored luminance.
    if (u.monochrome > 0.5) {
        col = u.tint * dot(col, float3(0.2126, 0.7152, 0.0722));
    }

    // Scan lines with a gaussian beam profile; a brighter beam blooms
    // wider, so highlights fill the gaps instead of going stripey.
    if (u.scanStrength > 0.0 && u.scanLines > 0.0) {
        float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
        float ph = fract(suv.y * u.scanLines) - 0.5;
        float sigma = max(u.beamWidth, 0.05) * 0.35 * (0.6 + 0.4 * luma);
        float beam = exp(-0.5 * ph * ph / (sigma * sigma));
        col *= 1.0 - u.scanStrength * (1.0 - beam);
    }

    // Phosphor mask, in device-pixel space so the pattern stays crisp.
    if (u.maskStrength > 0.0 && u.maskType > 0.5) {
        float2 px = uv * u.viewport;
        float stripe = u.maskPitchPx / 3.0;
        float open = 1.0;
        float idx;
        if (u.maskType < 1.5) { // aperture grille: unbroken RGB stripes
            idx = floor(px.x / stripe);
        } else if (u.maskType < 2.5) { // slot mask: staggered slots
            idx = floor(px.x / stripe);
            float column = floor(px.x / u.maskPitchPx);
            float slotPeriod = u.maskPitchPx * 1.5;
            float yph = fract((px.y + fmod(column, 2.0) * slotPeriod * 0.5) / slotPeriod);
            open = 0.6 + 0.4 * smoothstep(0.0, 0.15, yph) * smoothstep(1.0, 0.85, yph);
        } else { // shadow mask: alternate rows offset half a pitch
            float row = floor(px.y / u.maskPitchPx);
            idx = floor((px.x + fmod(row, 2.0) * u.maskPitchPx * 0.5) / stripe);
        }
        int channel = int(fmod(idx, 3.0) + 0.5) % 3;
        float3 maskCol = channel == 0 ? float3(1.0, 0.3, 0.3)
                       : channel == 1 ? float3(0.3, 1.0, 0.3)
                                      : float3(0.3, 0.3, 1.0);
        // ×1.55 ≈ keeps perceived brightness once the mask eats its share.
        col *= mix(float3(1.0), maskCol * open * 1.55, u.maskStrength);
    }

    // Mains hum bar drifting slowly up the screen.
    if (u.humBar > 0.0) {
        float center = 1.0 - fract(u.time * 0.10);
        float dy = abs(suv.y - center);
        dy = min(dy, 1.0 - dy);
        col *= 1.0 - u.humBar * exp(-dy * dy / 0.004);
    }

    // Video noise grain.
    if (u.noise > 0.0) {
        float n = crt_hash(uv * u.viewport + fract(u.time) * 941.0) - 0.5;
        col += n * u.noise;
    }

    // Degauss hue swirl collapsing from the edges, plus a brightness kick.
    if (degaussEnv > 0.0) {
        col = crt_hue_rotate(col, degaussEnv * 2.2 * (0.3 + r2) * sin(12.0 * u.degaussPhase));
        col *= 1.0 + degaussEnv * 0.22;
    }

    col *= 1.0 - u.vignette * r2 * 0.7;
    col *= screenMask;

    // Procedural bezel: shaded plastic with an inner shadow at the glass.
    if (u.bezelPx > 0.5) {
        float bezelNorm = u.bezelPx * 2.0 / max(screenPx, 1.0);
        float depth = clamp(dist / max(bezelNorm, 1e-3), 0.0, 1.0);
        float shade = mix(0.45, 1.0, smoothstep(0.0, 0.6, depth)); // inner shadow
        shade *= 1.0 + 0.12 * (0.5 - uv.y); // light from above
        float3 bezel = u.bezelColor * shade;
        col = mix(bezel, col, screenMask);
    }

    return float4(col, 1.0);
}
"""
