import SwiftUI

/// A scrolling note timeline across all voices sharing one pitch axis,
/// like a DAW piano roll — turns the "what note is each voice playing"
/// info already computed for the Oscilloscope into something more
/// musical to look at than a waveform. Reads `SIDVoiceChannel`'s
/// lower-rate, longer note-history buffer (~10 s at 30 Hz), not the
/// audio-rate waveform buffer.
struct SIDPianoRollView: View {
    let channels: [SIDVoiceChannel]

    private static let minMidi = 24.0 // C1
    private static let maxMidi = 96.0 // C7
    private static let colors: [Color] = [.green, .orange, .cyan, .pink, .yellow, .purple]

    var body: some View {
        Canvas { context, size in
            drawPitchGrid(context: context, size: size)
            for (index, channel) in channels.enumerated() {
                drawChannel(channel, color: Self.colors[index % Self.colors.count], context: context, size: size)
            }
        }
        .background(Color.black)
        .overlay(alignment: .topLeading) { legend }
    }

    private func drawPitchGrid(context: GraphicsContext, size: CGSize) {
        var octave = Int(Self.minMidi)
        while octave <= Int(Self.maxMidi) {
            let y = yForMidi(Double(octave), size: size)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
            octave += 12
        }
    }

    private func yForMidi(_ midi: Double, size: CGSize) -> CGFloat {
        let t = (midi - Self.minMidi) / (Self.maxMidi - Self.minMidi)
        return size.height * (1 - CGFloat(max(0, min(1, t))))
    }

    private func drawChannel(
        _ channel: SIDVoiceChannel, color: Color, context: GraphicsContext, size: CGSize
    ) {
        let history = channel.orderedNoteHistory
        guard history.count > 1 else { return }
        let stepX = size.width / CGFloat(history.count - 1)
        var currentPath: Path?
        for (index, entry) in history.enumerated() {
            let x = CGFloat(index) * stepX
            guard entry.gate, entry.frequencyHz > 1 else {
                if let path = currentPath {
                    context.stroke(path, with: .color(color), lineWidth: 4)
                }
                currentPath = nil
                continue
            }
            let midi = 69 + 12 * log2(entry.frequencyHz / 440)
            let y = yForMidi(midi, size: size)
            if currentPath == nil {
                currentPath = Path()
                currentPath?.move(to: CGPoint(x: x, y: y))
            } else {
                currentPath?.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if let path = currentPath {
            context.stroke(path, with: .color(color), lineWidth: 4)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.colors[index % Self.colors.count])
                        .frame(width: 10, height: 10)
                    Text("SID\(channel.chipIndex + 1).\(channel.voiceIndex + 1)")
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(4)
        .padding(6)
        .allowsHitTesting(false)
    }
}
