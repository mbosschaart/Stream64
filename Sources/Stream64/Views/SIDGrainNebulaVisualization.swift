import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDGrainNebulaVisualization {
    static let shaderSource = #"""

    float3 grainNebula(float2 p,constant Uniforms& u) {
        float3 c=0; float t=u.viewport.z;
        float pulse=clamp(u.energy.z+u.rhythm.x,0.0,1.0);
        // Fixed, bounded constellation. Analytical comet tails keep the same single
        // GPU pass in standalone, Club and Music Compo, without history textures.
        for(int i=0;i<96;i++) {
            float seed=float(i);
            float z=fract(seed*.6180339+t*.025);
            float speed=.08+u.energy.y*.10;
            float a=seed*2.39996+t*speed;
            float radius=sqrt((seed+.5)/96.0)*(.50+u.energy.x*.55);
            float4 v=u.voices[i%int(u.style.z)];
            float2 center=float2(cos(a),sin(a))*radius;
            center+=float2(sin(seed*4.0+t*2.0),cos(seed*3.0+t*1.7))*v.y*u.energy.y*.06;
            center*=.6+z*.65;
            float size=.005+z*.010+v.x*.005;
            float age=.45+v.x*.65+pulse*.35;
            float past=t-age;
            float2 tail=float2(cos(a-age*speed),sin(a-age*speed))*radius;
            tail+=float2(sin(seed*4.0+past*2.0),cos(seed*3.0+past*1.7))*v.y*u.energy.y*.06;
            // Do not wrap depth at the tail: that would draw a streak across the cloud.
            tail*=.6+max(0.0,z-age*.025)*.65;
            float2 trail=center-tail;
            float along=clamp(dot(p-tail,trail)/max(dot(trail,trail),.000001),0.0,1.0);
            float trailDistance=length(p-(tail+trail*along));
            float taper=.18+.82*along*along;
            float d=length(p-center);
            float3 tint=palette(z*.6+u.style.x*.3);
            float brightness=(.25+v.x+u.energy.w)*(.4+z);
            float haloWidth=size*(3.5+pulse*1.5+u.style.w);
            float halo=exp(-d*d/(haloWidth*haloWidth));
            float streak=exp(-trailDistance*trailDistance/(size*size*(.4+along)))*taper;
            float trailGlow=exp(-trailDistance*trailDistance/(haloWidth*haloWidth))*taper;
            c+=tint*brightness*(streak*.85+trailGlow*.20+halo*(.32+pulse*.25));
            // A pale hot centre inside the coloured halo retains the grain detail.
            c+=mix(tint,float3(1),.3)*line(d,size,u.style.w)*brightness*(1.15+pulse*.5);
        }
        return c;
    }
    """#
}
