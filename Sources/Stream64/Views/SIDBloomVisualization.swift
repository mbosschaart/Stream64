/// Neon flowers shaped by individual SID voices.
/// Owns this effect's Metal implementation; uniforms and rendering lifecycle
/// are supplied by SIDGenerativeRenderer.
enum SIDBloomVisualization {
    static let shaderSource = #"""
    float3 flower(float2 p, constant Uniforms& u) {
        float3 color = 0;
        int count = int(u.style.z);
        float t = u.viewport.z;
        for (int i=0; i<count; i++) {
            float4 v = u.voices[i];
            float angle = tau * float(i) / float(count) - 1.5708;
            float2 center = float2(cos(angle)*1.35,sin(angle)) * (count>=6 ? 0.50 : 0.42);
            float2 q = p-center;
            float a = atan2(q.y,q.x) + t * (0.08+v.y*0.12) * (i%2==0 ? 1.0 : -1.0);
            float petals = 5.0 + floor(v.y*12.0);
            float wave = pow(abs(cos(a*petals*0.5)), 0.5+v.z*2.0);
            float radius = (0.13+v.x*(count>=6 ? 0.26 : 0.36)) * (0.5+0.5*wave);
            float d = abs(length(q)-radius);
            float spokes = abs(sin(a*petals)) * length(q);
            float ink = line(d,0.0035+v.x*0.002,u.style.w);
            ink += line(spokes,0.002, u.style.w)*(1.0-smoothstep(radius-0.015,radius,length(q)))*0.35;
            ink += exp(-length(q)*80.0)*(0.2+v.x);
            color += palette(float(i)*0.145+0.82+v.z*0.08) * ink * (0.12+v.x*1.4+u.energy.w*0.12);
        }
        return color;
    }
    """#
}
