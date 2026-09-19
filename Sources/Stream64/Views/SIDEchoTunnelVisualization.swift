import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDEchoTunnelVisualization {
    static let shaderSource = #"""

    // Fresh voice marks are injected into a real previous-frame feedback texture.
    float3 echoTunnel(float2 p, constant Uniforms& u) {
        float3 c=0; float t=u.viewport.z;
        for(int i=0;i<int(u.style.z);i++) {
            float4 v=u.voices[i];
            float a=t*.35+float(i)*tau/u.style.z;
            float2 center=float2(cos(a),sin(a))*(.22+u.energy.x*.24);
            float2 q=p-center;
            float radius=.035+v.x*.10;
            float shape=max(abs(q.x),abs(q.y));
            c+=palette(float(i)/u.style.z+u.style.x*.2)
                *line(shape-radius,.006,u.style.w)*(.08+v.x+u.energy.z*u.rhythm.y);
        }
        return c;
    }
    fragment float4 sidEchoFragment(Raster in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                    texture2d<float> previous [[texture(0)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_zero,filter::linear);
        float2 uv=in.position.xy/u.viewport.xy;
        float2 p=(uv-.5)*2.0; p.x*=u.viewport.x/u.viewport.y;
        float dt=clamp(u.motion.x,0.0,.1);
        float angle=dt*(.10+u.energy.y*.3);
        float2 q=float2(cos(angle)*p.x-sin(angle)*p.y,sin(angle)*p.x+cos(angle)*p.y);
        q*=exp(-dt*(.25+u.energy.x*.7));
        q.x/=u.viewport.x/u.viewport.y;
        float3 history=previous.sample(s,q*.5+.5).rgb*exp(-dt*1.25);
        float3 fresh=1.0-exp(-echoTunnel(p,u)*dt*12.0);
        return float4(clamp(history+fresh,0.0,1.0),1);
    }
    """#
}
