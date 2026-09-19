import Foundation

enum SIDShowcaseGPU {
    static let shader = #"""
    float3 performanceShowcase(float2 pixel,constant PerformanceUniforms& u,texture2d_array<float> art,texture2d_array<float> labels) {
        constexpr sampler s(coord::normalized,address::clamp_to_zero,filter::linear);
        float2 size=u.viewport.xy, uv=pixel/size;
        float t=u.viewport.z; float3 c=float3(.012,.009,.035);
        bool portrait=size.x<size.y;
        float2 centers[6]={float2(.5,.26),float2(.18,.26),float2(.82,.26),
            float2(.18,.73),float2(.82,.73),float2(.5,.73)};
        float2 slot=size*(portrait?float2(.38,.23):float2(.25,.32));
        float width=min(slot.x,slot.y*1.3333); float2 extent=float2(width,width*.75);
        for(int i=0;i<6;i++) {
            int voice=(i+int(t/4))%max(1,min(9,int(u.style.z)));
            float4 v=u.voices[voice]; float3 color=performanceColor(float(voice)/u.style.z+.04);
            float2 center=portrait?float2(i%2==0?.25:.75,.18+float(i/2)*.30):centers[i];
            float pulse=u.rhythm.x*(.15+v.x*.85);
            float scale=.78+v.x*.12+pulse*.07;
            float2 q=(pixel-center*size)/(extent*scale);
            float angle=sin(t*(.55+v.y)+float(i))*(.025+v.x*.06);
            q=float2(cos(angle)*q.x-sin(angle)*q.y,sin(angle)*q.x+cos(angle)*q.y);
            int treatment=(int(t/6)+i)%3;
            float tear=sin(floor((q.y+.5)*18)*2.7+t*8+float(i))*(.005+v.x*.04);
            q.x+=tear*(treatment==0?1.0:.4);
            if(treatment==1) q.x+=sin(q.y*20+t*3)*v.z*v.x*.04;
            if(treatment==2) q*=1+sin(length(q)*15-t*5)*v.x*.05;
            float3 base=art.sample(s,q+.5,i).rgb;
            for(int echo=1;echo<=3;echo++) {
                float2 offset=float2(sin(t+float(i)),.35)*float(echo)*(.01+v.x*.025);
                c+=art.sample(s,(q-offset)/(1+float(echo)*v.x*.025)+.5,i).rgb*color*(.15+v.x*.4)/float(echo);
            }
            float unit=min(size.x/900,size.y/600);
            float2 captionCenter=center*size+float2(0,slot.y*.5+9*unit);
            float2 caption=(pixel-captionCenter)/(float2(512,32)*(.42*unit))+.5;
            c+=labels.sample(s,caption,i*9+voice).rgb*color;
            c+=base*mix(float3(1),color,.3)*(.8+v.x*.2);
            float2 delta=(uv-center)*float2(size.x/size.y,1);
            float ring=abs(length(delta)-.12-pulse*.015);
            c+=color*exp(-ring*size.y)*v.x*.12;
        }
        return c;
    }
    """#
}
