/// Layered luminous waves shaped by SID voices and audio energy.
/// Owns this effect's Metal implementation; uniforms and rendering lifecycle
/// are supplied by SIDGenerativeRenderer.
enum SIDNeonTideVisualization {
    static let shaderSource = #"""
    float3 sea(float2 p, constant Uniforms& u) {
        float3 color=0;
        float t=u.viewport.z;
        // Back to front: dark water beneath each crest occludes distant rows.
        for(int row=0;row<18;row++) {
            int index=row%int(u.style.z);
            float4 v=u.voices[index];
            float depth=float(row)/17.0;
            float baseline=-0.57+depth*1.35;
            float amplitude=(0.025+v.x*0.13+u.energy.x*0.045)*(0.4+depth);
            float wave=sin(p.x*(3.0+v.y*8.0)+t*(0.25+v.y*0.45)+float(row)*0.67);
            wave+=0.4*sin(p.x*7.0-t*0.32+float(row)*0.9+v.z*2.0);
            float y=baseline+wave*amplitude;
            color*=1.0-smoothstep(y-0.003,y+0.006,p.y)*0.94;
            float ink=line(p.y-y,0.0025+depth*0.002,u.style.w);
            color+=palette(0.63+float(index)*0.07+u.style.x*0.08)*ink
                *(0.3+v.x*1.35+u.energy.w*0.5)*(0.5+depth*0.65);
        }
        return color;
    }
    """#
}
