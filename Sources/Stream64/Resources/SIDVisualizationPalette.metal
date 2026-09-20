#include <metal_stdlib>
using namespace metal;

// Pepto PAL, in C64 colour-index order. Shared by the native and SwiftUI paths.
constant float3 sidC64Colors[16] = {
    float3(0,0,0), float3(255,255,255), float3(104,55,43), float3(112,164,178),
    float3(111,61,134), float3(88,141,67), float3(53,40,121), float3(184,199,111),
    float3(111,79,37), float3(67,57,0), float3(154,103,89), float3(68,68,68),
    float3(108,108,108), float3(154,210,132), float3(108,94,181), float3(149,149,149)
};
float3 sidC64Palette(float3 rgb) {
    float distance = 1e10;
    float3 selected = 0;
    for (int i=0; i<16; ++i) {
        float3 candidate = sidC64Colors[i]/255.0;
        float3 delta = clamp(rgb,0.0,1.0)-candidate;
        float score = dot(delta,delta);
        if (score < distance) { distance=score; selected=candidate; }
    }
    return selected;
}
[[ stitchable ]] half4 sidC64ColorEffect(float2 position, half4 color) {
    if (color.a <= 0) return color;
    return half4(half3(sidC64Palette(float3(color.rgb/color.a)))*color.a,color.a);
}
vertex float4 sidPaletteVertex(uint id [[vertex_id]]) {
    float2 p=float2((id<<1)&2,id&2);
    return float4(p*2-1,0,1);
}
fragment float4 sidPaletteFragment(float4 p [[position]], texture2d<float> source [[texture(0)]]) {
    return float4(sidC64Palette(source.read(uint2(p.xy)).rgb),1);
}
