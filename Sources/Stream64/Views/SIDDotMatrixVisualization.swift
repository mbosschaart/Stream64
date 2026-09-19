import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDDotMatrixVisualization {
    static let shaderSource = #"""

    float3 dotMatrix(float2 p,constant Uniforms& u) {
        float t=u.viewport.z;
        float2 grid=p*22.0, cell=floor(grid), f=fract(grid)-.5;
        int index=int(abs(cell.x+cell.y*3.0))%int(u.style.z);
        float4 v=u.voices[index];
        float wave=.5+.5*sin(length(cell)*.37-t*2.0+v.y*5.0);
        float radius=.055+wave*(.12+v.x*.22)+u.energy.z*.065;
        float dots=1.0-smoothstep(radius-.025,radius+.025,length(f));
        float blocks=step(.64,sidHash(floor(cell/4.0)))*u.energy.z;
        float mask=mix(dots,step(max(abs(f.x),abs(f.y)),.39),blocks);
        float3 ink=palette(float(index)/u.style.z*.6+u.style.x*.25);
        return ink*mask*(.25+v.x*1.1+u.energy.w*.65);
    }
    """#
}
