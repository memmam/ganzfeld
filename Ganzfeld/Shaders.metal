#include <metal_stdlib>
using namespace metal;

// Must match ShaderUniforms in Renderer.swift.
struct Uniforms {
    float4 color;      // premultiplied-alpha output for the treated eye(s)
    uint targetEye;    // view index of the treated eye, or 2 for both
    uint viewOffset;   // base view index of this pass (dedicated layout: the
                       // view being rendered; layered layout: 0)
    uint pad0;
    uint pad1;
};

constant uint kBothEyes = 2;

struct VertexOut {
    float4 position [[position]];
};

// Fullscreen triangle. In the layered layout the pass is amplified once per
// eye and the amplification view mappings supply both the render target
// array index and the viewport index, so the vertex function writes neither.
// Depth is written at the far plane (reverse-Z 0) so reprojection treats the
// color as infinitely distant.
vertex VertexOut ganzfeldVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -3.0),
        float2(-1.0,  1.0),
        float2( 3.0,  1.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

// The layer is composited over passthrough with premultiplied alpha:
//   result = color.rgb + (1 - color.a) * passthrough
// Untreated eyes get (0,0,0,0), i.e. untouched passthrough.
fragment float4 ganzfeldFragment(uint layer [[render_target_array_index]],
                                 constant Uniforms &uniforms [[buffer(0)]]) {
    uint view = uniforms.viewOffset + layer;
    bool treated = (uniforms.targetEye == kBothEyes) || (view == uniforms.targetEye);
    return treated ? uniforms.color : float4(0.0);
}
