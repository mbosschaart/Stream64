import Foundation

/// Effect-owned Metal implementation; shared transport and drawing live in Rendering.
enum SIDSignalCollageVisualization {
    static let shaderSource = #"""

    // Aspect-fit the supplied logo before applying the reactive tile offsets.
    float3 collageArtwork(float2 p,constant Uniforms& u,texture2d<float> logo) {
        constexpr sampler s(coord::normalized,address::clamp_to_zero,filter::linear);
        float aspect=float(logo.get_width())/float(logo.get_height());
        float width=min(u.viewport.x/u.viewport.y*.94,aspect*.88);
        float2 uv=p/float2(width,width/aspect)*.5+.5;
        float4 texel=logo.sample(s,uv);
        return texel.rgb*texel.a;
    }
    float3 signalCollage(float2 p,constant Uniforms& u,texture2d<float> logo) {
        float t=u.viewport.z, hit=u.energy.z*u.rhythm.y;
        float2 tile=floor(p*float2(5,7));
        float seed=sidHash(tile);
        int index=int(seed*100.0)%int(u.style.z);
        float4 v=u.voices[index];
        float shift=(sidHash(float2(tile.y,floor(t*5.0)))-.5)*(hit*.8+v.w*v.x*.25);
        float2 q=p+float2(shift,0);
        q*=1.0+step(.65,seed)*v.x*.5;
        float tear=step(.75,seed)*hit;
        float3 art=collageArtwork(q+float2(sin(t*.2)*.035,0),u,logo);
        float3 offset=collageArtwork(q+float2(.03+hit*.07,0),u,logo);
        art.r=mix(art.r,offset.r,hit);
        art=mix(art,art.brg,tear);
        float grain=sidHash(floor(p*250.0)+floor(t*12.0));
        float scan=.82+.18*cos(p.y*u.viewport.y*2.0);
        float seam=step(.025,fract(p.y*7.0));
        return art*scan*seam*(.65+u.energy.w*1.2+v.x*.3)*( .85+grain*.3);
    }
    """#
}
