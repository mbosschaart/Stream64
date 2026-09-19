import Foundation

/// Music-driven ring tunnel. This file owns both the effect's motion state
/// and its Metal implementation; the renderer only supplies input and time.
enum SIDPulseVortexVisualization {
    struct Motion {
        private var lastTime: TimeInterval?
        private var previousImpact: Float = 0
        private var previousBeat: Float = 0
        private var lastHit: TimeInterval?
        private var travel: Float = 0
        private var rotation: Float = 0
        private var punch: Float = 0
        private var bass: Float = 0

        mutating func advance(timestamp: TimeInterval, input: SIDGenerativeUniforms) -> SIMD4<Float> {
            let dt = Float(min(0.1, max(0, timestamp - (lastTime ?? timestamp))))
            lastTime = timestamp
            // Weight impacts by actual strength: register pitch updates also
            // set impactPulse, but must not become full-strength drum hits.
            let impact = input.energy.z * input.rhythm.y
            let beat = input.rhythm.x
            let onset = impact > 0.35 && impact > previousImpact + 0.12
            let beatOnset = beat > 0.08 && beat > previousBeat + 0.06
            if (onset || beatOnset), timestamp - (lastHit ?? -.infinity) >= 0.12 {
                lastHit = timestamp
                punch = max(0.5, max(impact, beat))
            } else {
                punch *= exp(-dt * 8)
            }
            previousImpact = impact
            previousBeat = beat
            bass += (input.energy.x - bass) * (1 - exp(-dt * 12))
            // Integrate velocity, never multiply absolute time by live energy:
            // changing loudness accelerates smoothly instead of teleporting.
            travel += dt * (0.15 + bass * 3.2 + punch * 5.5)
            rotation += dt * (0.035 + input.energy.y * 0.6 + punch * 0.9)
            let age = Float(min(10, max(0, timestamp - (lastHit ?? timestamp - 10))))
            return SIMD4(travel, rotation, age, punch)
        }
    }

    static let shaderSource = #"""
    float3 blackhole(float2 p, constant Uniforms& u) {
        float t = u.viewport.z;
        float bass = sqrt(clamp(u.energy.x,0.0,1.0));
        float hit = max(u.motion.w, u.energy.z*u.rhythm.y*0.7);
        float voiceEnergy=0, voicePitch=0, noise=0;
        for(int i=0;i<int(u.style.z);i++) {
            float4 v=u.voices[i];
            voiceEnergy+=v.x;
            voicePitch+=v.x*v.y;
            noise+=v.x*v.w;
        }
        voicePitch/=max(voiceEnergy,0.001);
        noise/=max(u.style.z,1.0);
        // Bass opens the tunnel; attacks give a short forward camera kick.
        p/=1.0+bass*0.28+hit*0.22;
        float pixels=170.0+120.0*u.style.x;
        p=floor(p*pixels)/pixels;
        float r=max(length(p),0.012);
        float a=atan2(p.y,p.x);
        float lobes=4.0+floor(voicePitch*5.0);
        float warp=sin(a*lobes+t*0.35+u.motion.y)*
            (0.025+bass*0.055+hit*0.13);
        warp+=sin(a*17.0-t*2.0)*noise*0.025;
        float depth=-log(max(0.015,r+0.035+warp*min(r,0.5)));
        float phase=depth*5.0-u.motion.x-t*0.06;
        float ring=abs(fract(phase)-0.5);
        float rotation=a+u.motion.y+depth*(0.5+u.style.y*0.5);
        float hue=rotation/tau+floor(phase)*0.08+u.style.x*0.25+voicePitch*0.3;
        float stripe=0.65+0.35*sin(rotation*9.0+depth*3.0);
        float light=line(ring,0.02+bass*0.055+hit*0.035,u.style.w);
        // A transient launches a bright expanding ring with a short coloured
        // wake. It travels independently of the continuously moving tunnel.
        float age=u.motion.z;
        float radius=0.06+age*2.6;
        float fade=exp(-age*2.5)*step(age,1.1);
        float shock=line(r-radius,0.014+age*0.018,1.0)*fade;
        float wake=exp(-abs(r-radius+0.075)*22.0)*fade*0.18;
        float core=exp(-r*24.0)*(0.18+u.energy.w*0.7+hit*2.3);
        float3 color=palette(hue)*light*stripe*(0.22+u.energy.w*1.5+hit*1.8);
        color+=mix(palette(hue+0.15),float3(0.65,0.85,1),0.55)*(shock*2.5+wake);
        color+=float3(1,0.34+u.style.x*0.25,0.08)*core;
        return color;
    }
    """#
}
