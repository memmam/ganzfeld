#include <metal_stdlib>
using namespace metal;

// Must match ShaderUniforms in Renderer.swift.
struct Uniforms {
    float4 color;      // premultiplied-alpha output for the treated eye
    uint targetEye;    // render target array index of the treated eye
    uint pad0;
    uint pad1;
    uint pad2;
};

struct VertexOut {
    float4 position [[position]];
    uint layer [[render_target_array_index]];
};

// Fullscreen triangle, amplified once per eye. Depth is written at the far
// plane (reverse-Z 0) so reprojection treats the color as infinitely distant.
vertex VertexOut ganzfeldVertex(uint vertexID [[vertex_id]],
                                ushort amplificationID [[amplification_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -3.0),
        float2(-1.0,  1.0),
        float2( 3.0,  1.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.layer = uint(amplificationID);
    return out;
}

// The layer is composited over passthrough with premultiplied alpha:
//   result = color.rgb + (1 - color.a) * passthrough
// The untreated eye gets (0,0,0,0), i.e. untouched passthrough.
fragment float4 ganzfeldFragment(uint layer [[render_target_array_index]],
                                 constant Uniforms &uniforms [[buffer(0)]]) {
    return (layer == uniforms.targetEye) ? uniforms.color : float4(0.0);
}
