import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDGrainNebulaVisualization {
    static let shaderSource = #"""

    float3 grainNebula(float2 p,constant Uniforms& u) {
        float3 c=0; float t=u.viewport.z;
        // Fixed, bounded constellation; analytical projection needs no particle buffers.
        for(int i=0;i<96;i++) {
            float seed=float(i);
            float z=fract(seed*.6180339+t*.025);
            float a=seed*2.39996+t*(.08+u.energy.y*.10);
            float radius=sqrt((seed+.5)/96.0)*(.50+u.energy.x*.55);
            float4 v=u.voices[i%int(u.style.z)];
            float2 center=float2(cos(a),sin(a))*radius;
            center+=float2(sin(seed*4.0+t*2.0),cos(seed*3.0+t*1.7))*v.y*u.energy.y*.06;
            center*=.6+z*.65;
            float size=.005+z*.010+v.x*.005;
            float d=length(p-center);
            c+=palette(z*.6+u.style.x*.3)*line(d,size,u.style.w)*(.25+v.x+u.energy.w)*(.4+z);
        }
        return c;
    }
    """#
}
