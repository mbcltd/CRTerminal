/// MSL compiled at runtime via `makeLibrary(source:)` — SwiftPM's .metal
/// handling is unreliable under plain `swift build`/`swift test`, and the
/// one-time compile costs single-digit milliseconds at startup.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewport;
};

struct BgInstance {
    float2 origin;
    float2 size;
    uint color;
};

struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    uint color;
};

struct ImageInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

static float4 unpack(uint c) {
    return float4((c >> 24) & 0xFFu, (c >> 16) & 0xFFu, (c >> 8) & 0xFFu, c & 0xFFu) / 255.0;
}

static float4 toNDC(float2 p, float2 viewport) {
    return float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
}

vertex VSOut bg_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       const device BgInstance *instances [[buffer(0)]],
                       constant Uniforms &u [[buffer(1)]]) {
    BgInstance inst = instances[iid];
    float2 corner = float2(vid & 1u, vid >> 1u);
    VSOut out;
    out.position = toNDC(inst.origin + corner * inst.size, u.viewport);
    out.uv = corner;
    out.color = unpack(inst.color);
    return out;
}

fragment float4 bg_fragment(VSOut in [[stage_in]]) {
    return in.color;
}

vertex VSOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device GlyphInstance *instances [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]]) {
    GlyphInstance inst = instances[iid];
    float2 corner = float2(vid & 1u, vid >> 1u);
    VSOut out;
    out.position = toNDC(inst.origin + corner * inst.size, u.viewport);
    out.uv = inst.uvOrigin + corner * inst.uvSize;
    out.color = unpack(inst.color);
    return out;
}

fragment float4 glyph_fragment(VSOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float a = atlas.sample(s, in.uv).r;
    return float4(in.color.rgb, in.color.a * a);
}

// Color (emoji) glyphs: premultiplied BGRA sampled directly, no tint.
fragment float4 color_glyph_fragment(VSOut in [[stage_in]],
                                     texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear);
    return atlas.sample(s, in.uv);
}

// Inline images (kitty / sixel / iTerm2): premultiplied RGBA, one texture per
// placement, sampled with the source-crop UVs from the instance.
vertex VSOut image_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device ImageInstance *instances [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]]) {
    ImageInstance inst = instances[iid];
    float2 corner = float2(vid & 1u, vid >> 1u);
    VSOut out;
    out.position = toNDC(inst.origin + corner * inst.size, u.viewport);
    out.uv = inst.uvOrigin + corner * inst.uvSize;
    out.color = float4(1.0);
    return out;
}

fragment float4 image_fragment(VSOut in [[stage_in]],
                               texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    return image.sample(s, in.uv);
}
"""
