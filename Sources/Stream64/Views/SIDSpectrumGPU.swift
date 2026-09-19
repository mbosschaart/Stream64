import Foundation

enum SIDSpectrumGPU {
    static let shader = #"""
    float3 performanceSpectrum(float2 uv,constant PerformanceUniforms& u,const device float* data) {
        if(u.motion.w<1) return float3(0);
        int bin=min(47,int(uv.x*48)); float v=spectrumValue(data,int(u.motion.w)-1,bin);
        float edge=min(fract(uv.x*48),1-fract(uv.x*48))*u.viewport.x/48;
        float ink=step(1.0-uv.y,v)*smoothstep(0.0,1.0,edge);
        float3 col=v>.8 ? float3(1,.1,.1) : v>.55 ? float3(1,1,.1) : float3(.1,1,.2);
        float bloom=u.style.w*.25*exp(-abs(1-uv.y-v)*u.viewport.y/4);
        return col*(ink+bloom);
    }
    """#
}
