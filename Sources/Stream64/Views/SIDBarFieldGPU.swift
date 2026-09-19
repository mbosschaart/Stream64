import Foundation

enum SIDBarFieldGPU {
    static let shader = #"""
    float3 performanceBarField(float2 uv,constant PerformanceUniforms& u,const device float* data,bool wire) {
        int count=min(int(u.motion.w),wire?56:14); float3 c=0;
        for(int i=0;i<count;i++) {
            float depth=float(count-1-i)/max(1,count-1);
            float width=.86*(1-depth*.22), x=(uv.x-depth*.14)/width;
            if(x<0 || x>1) continue;
            float bin=x*47, f=fract(bin);
            int row=int(u.motion.w)-count+i;
            float value=spectrumValue(data,row,int(bin));
            float base=.86-depth*.58, top=base-value*.46;
            if(wire) {
                value=mix(value,spectrumValue(data,row,int(bin)+1),f);
                float distance=abs(uv.y-(base-value*.46))*u.viewport.y;
                c+=float3(.1,1,.3)*exp(-distance*distance)*(.15+(1-depth)*.85);
            } else if(uv.y>=top && uv.y<=base && f<.72) {
                float3 color=value<.34 ? mix(float3(.15,.05,.55),float3(.4,.05,.9),value/.34)
                    : value<.67 ? mix(float3(.4,.05,.9),float3(.9,.15,.6),(value-.34)/.33)
                    : mix(float3(.9,.15,.6),float3(1,.7,0),(value-.67)/.33);
                c=color*(.35+(1-depth)*.65);
            }
        }
        return c;
    }
    """#
}
