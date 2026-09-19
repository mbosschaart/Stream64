import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDPixelRiptideVisualization {
    static let shaderSource = #"""

    float3 pixelRiptide(float2 p, constant Uniforms& u) {
        float t=u.viewport.z;
        float hit=u.energy.z*u.rhythm.y;
        float row=floor(p.y*36.0);
        float noise=0.0, sustain=0.0;
        for(int i=0;i<int(u.style.z);i++) {
            noise+=u.voices[i].w*u.voices[i].x;
            sustain+=u.voices[i].x/u.style.z;
        }
        float tear=step(0.56,sidHash(float2(row,floor(t*9.0))));
        float2 q=p;
        q.x+=tear*(sidHash(float2(row,4.0))-.5)*(hit+noise*.3)*1.5;
        float width=.035+sustain*.28+hit*.35;
        float2 cell=floor(float2(q.x/width+t*.9,row));
        float seed=sidHash(cell);
        float2 f=fract(float2(q.x/width+t*.9,q.y*36.0));
        float mask=step(.08,f.x)*step(.15,f.y)*step(seed,.35+u.energy.w*.55);
        float3 c=palette(seed*.6+u.style.x*.35)*mask*(.12+u.energy.w*1.5);
        float slash=line(fract(q.x*2.0-q.y*.3-t*.15)-.5,.006,u.style.w);
        return c+palette(.52)*slash*hit*2.0;
    }
    """#
}
