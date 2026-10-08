#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float3 col; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(0, 0.7), float2(-0.7, -0.6), float2(0.7, -0.6) };
    const float3 c[3] = { float3(1, 0, 0), float3(0, 1, 0), float3(0, 0, 1) };
    VOut o; o.pos = float4(p[vid], 0, 1); o.col = c[vid];
    return o;
}

fragment float4 fmain(VOut in [[stage_in]], constant float &hue [[buffer(0)]]) {
    float3 shifted = in.col.zxy * hue + in.col * (1 - hue);
    return float4(shifted, 1);
}
