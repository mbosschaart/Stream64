import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDShardStormVisualization {
    static let shaderSource = #"""

    float3 shardRotate(float3 p,float a) {
        p.xz=float2(cos(a)*p.x-sin(a)*p.z,sin(a)*p.x+cos(a)*p.z);
        p.yz=float2(cos(a*.7)*p.y-sin(a*.7)*p.z,sin(a*.7)*p.y+cos(a*.7)*p.z);
        return p;
    }
    float shardDistance(float3 p,constant Uniforms& u) {
        float result=10.0;
        for(int i=0;i<6;i++) {
            float a=float(i)*tau/6.0;
            float4 v=u.voices[i%int(u.style.z)];
            float spread=.27+u.energy.z*u.rhythm.y*.48+u.energy.x*.12;
            float3 center=float3(cos(a),sin(a),sin(a*2.0)*.5)*spread;
            float3 q=shardRotate(p-center,u.viewport.z*.38+float(i));
            float radius=.19+v.x*.11;
            // Octahedra have genuinely planar faces, unlike smooth spheres.
            result=min(result,(abs(q.x)+abs(q.y)+abs(q.z)-radius)*.57735);
        }
        return result;
    }
    float3 shardStorm(float2 p,constant Uniforms& u) {
        float3 ray=normalize(float3(p,-2.4)), origin=float3(0,0,2.6);
        float travel=0.0,d=1.0; float3 pos=origin;
        for(int step=0;step<48;step++) {
            pos=origin+ray*travel; d=shardDistance(pos,u);
            if(d<.002 || travel>4.5) break;
            travel+=max(d,.001);
        }
        if(d>.004) return float3(0);
        float e=.003;
        float3 normal=normalize(float3(shardDistance(pos+float3(e,0,0),u)-shardDistance(pos-float3(e,0,0),u),
            shardDistance(pos+float3(0,e,0),u)-shardDistance(pos-float3(0,e,0),u),
            shardDistance(pos+float3(0,0,e),u)-shardDistance(pos-float3(0,0,e),u)));
        float light=.18+max(0.0,dot(normal,normalize(float3(-.5,.8,1))));
        float rim=pow(1.0-max(0.0,dot(normal,-ray)),3.0);
        return palette(pos.x*.4+pos.y*.25+u.style.x*.4)*light*(.6+u.energy.w*1.7)
             +palette(.55)*rim*(.3+u.style.w*.5);
    }
    """#
}
