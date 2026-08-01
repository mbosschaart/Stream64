import SwiftUI

/// A per-chip diagram of its 3 voices with a connector between a voice and
/// its ring-mod/sync "neighbor" (voice 1 ← voice 3, voice 2 ← voice 1,
/// voice 3 ← voice 2, circularly — matching `SIDOscilloscopeViewModel`'s
/// own neighbor-phase wiring for the synth) that lights up only while
/// that voice's `SYNC`/`RING` control bits are actually set. Makes visible
/// information the synth already decodes but — per `HANDOVER.md` §15 —
/// only partially (ring mod) or not at all (sync) acts on.
struct SIDWiringDiagramView: View {
    let channels: [SIDVoiceChannel]
    let chipCount: Int

    var body: some View {
        GeometryReader { geometry in
            let rows = max(chipCount, 1)
            let rowHeight = geometry.size.height / CGFloat(rows)
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    SIDChipWiringDiagram(
                        voices: Array(channels[(row * 3)..<min(row * 3 + 3, channels.count)]))
                        .frame(height: rowHeight)
                }
            }
        }
        .background(Color.black)
    }
}

private struct SIDChipWiringDiagram: View {
    let voices: [SIDVoiceChannel] // 3 elements, in voice-index order

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height) * 0.8
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let boxWidth: CGFloat = min(size * 0.34, 120)
            let boxHeight = boxWidth * 0.62
            let radius = size / 2 - boxWidth / 2

            // Triangle: voice 0 at top, 1 bottom-left, 2 bottom-right.
            let positions: [CGPoint] = (0..<3).map { i in
                let angle = Angle.degrees(-90 + Double(i) * 120).radians
                return CGPoint(
                    x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y + radius * CGFloat(sin(angle)))
            }

            ZStack {
                Canvas { context, _ in
                    for voice in 0..<3 {
                        guard voices.indices.contains(voice) else { continue }
                        let neighbor = (voice + 2) % 3 // circular: 0←2, 1←0, 2←1
                        guard voices.indices.contains(neighbor) else { continue }
                        let sync = voices[voice].registers.syncEnabled
                        let ring = voices[voice].registers.ringModEnabled
                        guard sync || ring else { continue }
                        let color: Color = sync && ring ? .orange : (sync ? .yellow : .purple)

                        var path = Path()
                        path.move(to: positions[neighbor])
                        path.addLine(to: positions[voice])
                        context.stroke(path, with: .color(color), lineWidth: 3)

                        // A filled dot at the receiving end stands in for
                        // an arrowhead — simpler geometry, still shows
                        // direction (neighbor → voice).
                        let dot = CGRect(x: positions[voice].x - 5, y: positions[voice].y - 5, width: 10, height: 10)
                        context.fill(Path(ellipseIn: dot), with: .color(color))
                    }
                }
                ForEach(0..<3, id: \.self) { voice in
                    if voices.indices.contains(voice) {
                        SIDWiringVoiceBox(channel: voices[voice])
                            .frame(width: boxWidth, height: boxHeight)
                            .position(positions[voice])
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let first = voices.first {
                    Text("SID \(first.chipIndex + 1)")
                        .font(.caption).bold()
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(6)
                }
            }
        }
    }
}

private struct SIDWiringVoiceBox: View {
    let channel: SIDVoiceChannel

    var body: some View {
        VStack(spacing: 2) {
            Text("Channel \(channel.voiceIndex + 1)")
                .font(.callout).bold()
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                if channel.registers.syncEnabled {
                    Text("SYNC").font(.system(size: 9)).foregroundStyle(.yellow)
                }
                if channel.registers.ringModEnabled {
                    Text("RING").font(.system(size: 9)).foregroundStyle(.purple)
                }
                if !channel.registers.syncEnabled && !channel.registers.ringModEnabled {
                    Text("—").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(channel.registers.gate ? Color.green : Color.white.opacity(0.2), lineWidth: 1.5))
    }
}
