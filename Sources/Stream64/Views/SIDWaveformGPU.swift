import Foundation

enum SIDWaveformGPU {
    static let shader = #"""
    float3 performanceWaveform(float2 uv,constant PerformanceUniforms& u,const device float* data) {
        float3 c=0; float x=uv.x*255; int k=min(254,int(x));
        for(int voice=0;voice<min(9,int(u.style.z));voice++) {
            float y=mix(data[voice*256+k],data[voice*256+k+1],fract(x));
            float distance=abs(uv.y-(.5-y*.47))*u.viewport.y;
            float ink=exp(-distance*distance/1.5)+u.style.w*.3*exp(-distance/5);
            c+=performanceColor(float(voice)*.145+.82)*ink;
        }
        return c;
    }
    """#
}
