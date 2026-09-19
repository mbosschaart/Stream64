import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDNeonOrbitVisualization {
    static let shaderSource = #"""

    float3 neonOrbit(float2 p, constant Uniforms& u) {
        float3 c=0; float t=u.viewport.z;
        for(int i=0;i<int(u.style.z);i++) {
            float4 v=u.voices[i]; float a=t*(.16+v.y*.3)+float(i)*tau/u.style.z;
            float2 center=float2(cos(a),sin(a))*(.32+u.energy.x*.12);
            float r=.12+v.x*.20;
            float ring=line(length(p-center)-r,.003+v.x*.005,u.style.w);
            float2 other=float2(cos(a+2.1),sin(a+2.1))*.45;
            float wire=line(segment(p,center,other),.0025,u.style.w);
            float dotmark=line(length(p-center),.012+u.energy.z*.012,u.style.w);
            c+=palette(float(i)/u.style.z+u.style.x*.25)*(ring+wire*.55+dotmark)*(.2+v.x*1.6+u.energy.w*.3);
        }
        return c;
    }
    """#
}
