import AppKit
import SwiftUI

/// A six-object SID stage: all artwork stays visible, while voice ownership
/// and the distortion treatment rotate. Uses only shared-engine refreshes.
struct SIDShowcaseView: View {
    let channels: [SIDVoiceChannel]
    let filters: [SIDFilterRegisters]
    let rhythm: KAOSRhythmState
    var glow = false
    var underPressure = false
    @State private var startedAt = ProcessInfo.processInfo.systemUptime

    var body: some View {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        let snapshot = SIDGenerativeUniforms.snapshot(mode: .sidShowcase, channels: channels,
            filters: filters, rhythm: rhythm, glow: glow)
        SIDShowcaseStage(input: snapshot, time: elapsed, underPressure: underPressure)
    }
}

enum SIDShowcaseLayout {
    static let names = ["COMPUTER", "FLOPPY DRIVE", "TAPE", "DISK", "JOYSTICK", "1702 MONITOR"]
    static let resources = ["kaos-c64", "kaos-1541", "kaos-cassette", "kaos-floppy", "kaos-joystick", "showcase-1702"]
    static let assignmentInterval: TimeInterval = 4

    static func voice(for image: Int, count: Int, time: TimeInterval) -> Int {
        let turn = Int(max(0, time) / assignmentInterval)
        return (image + turn) % max(1, count)
    }

    static func slot(for image: Int, size: CGSize) -> CGRect {
        let portrait = size.width < size.height
        let centers: [CGPoint] = portrait
            ? [.init(x: 0.25, y: 0.18), .init(x: 0.75, y: 0.18),
               .init(x: 0.25, y: 0.48), .init(x: 0.75, y: 0.48),
               .init(x: 0.25, y: 0.78), .init(x: 0.75, y: 0.78)]
            : [.init(x: 0.5, y: 0.26), .init(x: 0.18, y: 0.26), .init(x: 0.82, y: 0.26),
               .init(x: 0.18, y: 0.73), .init(x: 0.82, y: 0.73), .init(x: 0.5, y: 0.73)]
        let width = size.width * (portrait ? 0.38 : 0.25)
        let height = size.height * (portrait ? 0.23 : 0.32)
        let center = centers[image]
        return CGRect(x: center.x * size.width - width / 2,
                      y: center.y * size.height - height / 2, width: width, height: height)
    }

    static let images: [NSImage?] = resources.map { name in
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? (ResourceBundle.isPackagedApp ? nil : Bundle.module.url(forResource: name, withExtension: "png"))
        return url.flatMap { NSImage(contentsOf: $0) }
    }
}

/// Explicit time/input also allow deterministic render and assignment checks.
struct SIDShowcaseStage: View {
    let input: SIDGenerativeUniforms
    let time: TimeInterval
    var underPressure = false

    private var voices: [SIMD4<Float>] {
        [input.voice0, input.voice1, input.voice2, input.voice3, input.voice4, input.voice5]
    }

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 900, size.height / 600)
            let count = min(6, max(1, Int(input.style.z)))
            let beat = Double(input.rhythm.x)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.012, green: 0.009, blue: 0.035)))
            let hub = CGPoint(x: size.width / 2, y: size.height * 0.49)
            // A rotating radar halo and flowing connections bind the six objects into one stage.
            for ring in 0..<4 {
                let radius = min(size.width, size.height) * (0.15 + CGFloat(ring) * 0.1 + CGFloat(input.energy.x) * 0.025)
                let rect = CGRect(x: hub.x-radius, y: hub.y-radius, width: radius*2, height: radius*2)
                context.stroke(Path(ellipseIn: rect), with: .color(.cyan.opacity(0.04 + beat * 0.08)),
                    style: StrokeStyle(lineWidth: max(0.5, unit), dash: [4*unit, 12*unit], dashPhase: CGFloat(time * 12)))
            }
            for index in 0..<SIDShowcaseLayout.resources.count {
                let voice = SIDShowcaseLayout.voice(for: index, count: count, time: time)
                let v = voices[voice]
                let color = Color(hue: Double(voice) / Double(count) + 0.04,
                                  saturation: 0.8, brightness: 1)
                let slot = SIDShowcaseLayout.slot(for: index, size: size)
                let center = CGPoint(x: slot.midX, y: slot.midY)
                var link = Path()
                link.move(to: hub)
                link.addQuadCurve(to: center, control: CGPoint(x: center.x, y: hub.y))
                context.stroke(link, with: .color(color.opacity(0.10 + Double(v.x)*0.25)),
                    style: StrokeStyle(lineWidth: max(0.6, unit), dash: [6*unit, 9*unit], dashPhase: CGFloat(-time*30)))
                drawObject(index, voice: voice, signal: v, slot: slot,
                           color: color, unit: unit, context: context)
            }
            context.draw(Text("SID SHOWCASE")
                .font(.system(size: max(10, 16*unit), weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65)),
                at: CGPoint(x: size.width/2, y: size.height * 0.035))
        }
    }

    private func drawObject(_ index: Int, voice: Int, signal: SIMD4<Float>, slot: CGRect,
                            color: Color, unit: CGFloat, context: GraphicsContext) {
        guard let asset = SIDShowcaseLayout.images[index] else { return }
        let level = CGFloat(signal.x)
        let pitch = CGFloat(signal.y)
        let pulse = CGFloat(input.rhythm.x) * (0.15 + level * 0.85)
        let treatment = (Int(time / 6) + index) % 3
        let scale = 0.78 + level * 0.12 + pulse * 0.07
        let aspect = asset.size.width / max(1, asset.size.height)
        let width = min(slot.width, slot.height * aspect) * scale
        let height = width / aspect
        let rect = CGRect(x: -width/2, y: -height/2, width: width, height: height)
        var art = context
        art.translateBy(x: slot.midX, y: slot.midY)
        let tilt = sin(time * (0.55 + Double(pitch)) + Double(index)) * Double(0.025 + level * 0.06)
        art.rotate(by: .radians(tilt))

        // Colored persistence echoes remain behind the crisp, recognizable line art.
        let echoes = underPressure ? 1 : 3
        for echo in (1...echoes).reversed() {
            var trail = art
            let distance = CGFloat(echo) * (3 + level * 7) * unit
            trail.translateBy(x: sin(time + Double(index)) * distance, y: distance * 0.35)
            trail.scaleBy(x: 1 + CGFloat(echo)*level*0.025, y: 1 + CGFloat(echo)*level*0.025)
            trail.addFilter(.colorMultiply(color))
            trail.opacity = (0.2 + Double(level)*0.65) / Double(echo)
            if !underPressure && (echo == 1 || input.style.w > 0) {
                trail.addFilter(.blur(radius: (3 + CGFloat(echo)*2) * unit))
            }
            trail.draw(Image(nsImage: asset), in: rect)
        }
        // Slice displacement gives each assigned voice its own elastic/glitch character.
        // Fewer slices under main-video pressure; fixed small bounds on all work.
        let slices = underPressure ? 8 : 18
        for slice in 0..<slices {
            let y = rect.minY + height * CGFloat(slice) / CGFloat(slices)
            let phase = Double(slice) * (0.4 + Double(pitch)) + time * (2 + Double(pitch)*4)
            let bend: CGFloat
            switch treatment {
            case 0: bend = sin(phase) * level * 9 * unit
            case 1: bend = sin(phase*0.35) * level * 6 * unit + CGFloat(signal.w) * level * sin(phase*5) * 8 * unit
            default: bend = sin(phase + Double(signal.z)*6) * level * 12 * unit
            }
            var strip = art
            strip.clip(to: Path(CGRect(x: rect.minX - 20*unit, y: y,
                                      width: width + 40*unit, height: height / CGFloat(slices) + 0.5)))
            strip.translateBy(x: bend, y: 0)
            strip.opacity = 0.8 + Double(level) * 0.2
            strip.addFilter(.colorMultiply(Color(hue: Double(voice) / Double(max(1, Int(input.style.z))) + 0.04,
                                                saturation: 0.5, brightness: 1)))
            strip.draw(Image(nsImage: asset), in: rect)
        }
        // The voice identifier travels with the assignment, so sharing voices on
        // a single SID and rotating through all six on dual SID are visible.
        let caption = "\(SIDShowcaseLayout.names[index])  ·  SID \(voice / 3 + 1) V\(voice % 3 + 1)"
        context.draw(Text(caption).font(.system(size: max(7, 10*unit), weight: .semibold, design: .monospaced))
            .foregroundStyle(color), at: CGPoint(x: slot.midX, y: slot.maxY + 9*unit))
    }
}
