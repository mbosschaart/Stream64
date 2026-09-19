/// Arrow lattice steered by SID voice activity and noise.
/// Owns this effect's Metal implementation; uniforms and rendering lifecycle
/// are supplied by SIDGenerativeRenderer.
enum SIDVectorFlowVisualization {
    static let shaderSource = #"""
    float3 vectorField(float2 p, constant Uniforms& u) {
        float grid = 22.0;
        float2 cell = floor(p*grid);
        float2 center = (cell+0.5)/grid;
        float2 local = (p-center)*grid;
        float t = u.viewport.z;
        float2 flow = float2(sin(center.y*3.0+t*0.22),cos(center.x*3.0-t*0.18))*0.35;
        float activity = 0;
        for(int i=0;i<int(u.style.z);i++) {
            float4 v=u.voices[i];
            float a=float(i)*tau/u.style.z+t*0.06;
            float2 delta=center-float2(cos(a),sin(a))*0.5;
            float influence=(0.05+v.x)/(0.15+dot(delta,delta)*4.0);
            flow+=float2(-delta.y,delta.x)*influence*(0.5+v.y*2.0);
            flow+=v.w*v.x*0.12*float2(sin(t*3.0+cell.y),cos(t*2.0+cell.x));
            activity+=influence;
        }
        float theta=atan2(flow.y,flow.x);
        float2 q=float2(cos(theta)*local.x+sin(theta)*local.y,
                        -sin(theta)*local.x+cos(theta)*local.y);
        float d=min(segment(q,float2(-0.3,0),float2(0.3,0)),
                    min(segment(q,float2(0.3,0),float2(0.05,0.19)),
                        segment(q,float2(0.3,0),float2(0.05,-0.19))));
        // A wider, brighter stroke keeps the small arrows readable at window size.
        float ink=line(d,0.055+u.energy.x*0.035,u.style.w);
        return palette(theta/tau*0.35+center.y*0.15+0.52+u.style.x*0.15)
            *ink*(0.45+min(activity,1.0)*1.3+u.energy.w*0.6);
    }
    """#
}
