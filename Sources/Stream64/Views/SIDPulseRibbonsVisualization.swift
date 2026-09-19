import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDPulseRibbonsVisualization {
    static let shaderSource = #"""

    float3 pulseRibbons(float2 p, constant Uniforms& u) {
        float3 c=0; float t=u.viewport.z;
        for(int i=0;i<int(u.style.z);i++) {
            float4 v=u.voices[i];
            float center=-.8+1.6*(float(i)+.5)/u.style.z;
            float wave=sin(p.x*(2.0+v.y*9.0)+t*(.6+v.y)+float(i));
            float y=center+wave*(.015+v.x*.10+u.energy.z*.035);
            float thickness=.006+v.x*.025+u.energy.x*.009;
            float carrier=.7+.3*cos(p.x*5.0-t*2.0+float(i));
            c+=palette(float(i)/u.style.z*.8+u.style.x*.2)
                *line(p.y-y,thickness,u.style.w)*(.25+v.x*2.0+u.energy.w*.5)*carrier;
            c+=palette(float(i)/u.style.z*.8)*line(p.y-y-.055,.002,u.style.w)*v.x*.35;
        }
        return c;
    }
    """#
}
