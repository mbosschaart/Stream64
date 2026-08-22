import SwiftUI

/// A note-on/onset detected in a voice's history — the moment its gate
/// turns on, or it slides to a clearly different pitch without re-gating.
/// Not private so it (and `SIDVoiceLineupView.onsets(for:)`) can be
/// exercised directly by unit tests via `@testable import`.
struct SIDLineupOnset: Equatable {
    let index: Int
    let noteName: String
}

/// A "lineup" of all voices as stacked, time-aligned lanes with note-name
/// labels at each onset and dashed guide lines wherever two or more
/// voices land a new note at (nearly) the same moment — this app's take
/// on Sonic Lineup's stacked, chord/beat-annotated multi-track alignment
/// view. Sonic Lineup compares several separate *recordings* of the same
/// piece; there's only one live source here, so this instead lines up
/// this device's own voices against each other, using the same
/// `orderedNoteHistory` ring buffer the Piano Roll mode reads (~10 s at
/// 30 Hz) rather than a full per-voice spectrogram.
struct SIDVoiceLineupView: View {
    let channels: [SIDVoiceChannel]

    /// How many history samples count as "close enough" to call two
    /// voices' onsets simultaneous — a few ticks of slop at 30 Hz.
    private static let alignmentToleranceSamples = 3

    var body: some View {
        GeometryReader { geometry in
            let historyLength = channels.first?.orderedNoteHistory.count ?? 1
            let allOnsets = channels.map { Self.onsets(for: $0) }
            let laneHeight = geometry.size.height / CGFloat(max(channels.count, 1))

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
                        SIDVoiceLineupLane(channel: channel, onsets: allOnsets[index])
                            .frame(height: laneHeight)
                    }
                }
                Canvas { context, size in
                    Self.drawAlignmentGuides(
                        allOnsets: allOnsets, historyLength: historyLength, size: size, context: context)
                }
                .allowsHitTesting(false)
            }
        }
        .background(Color.black)
    }

    static func onsets(for channel: SIDVoiceChannel) -> [SIDLineupOnset] {
        let history = channel.orderedNoteHistory
        var result: [SIDLineupOnset] = []
        var wasGated = false
        var previousFrequency = 0.0
        for (index, entry) in history.enumerated() {
            guard entry.gate, entry.frequencyHz > 1 else {
                wasGated = false
                continue
            }
            let isNewNote = !wasGated || abs(entry.frequencyHz - previousFrequency) > previousFrequency * 0.03
            if isNewNote {
                result.append(SIDLineupOnset(index: index, noteName: SIDVoiceChannel.noteName(forHz: entry.frequencyHz)))
            }
            wasGated = true
            previousFrequency = entry.frequencyHz
        }
        return result
    }

    /// Groups onsets across all voices whose adjacent events land within
    /// `alignmentToleranceSamples` and draws a shared
    /// vertical guide through them — a chiptune's equivalent of Sonic
    /// Lineup's cross-track alignment markers, highlighting where two or
    /// more voices change notes together (the closest thing a 3-voice
    /// chip has to a "chord hit").
    private static func drawAlignmentGuides(
        allOnsets: [[SIDLineupOnset]], historyLength: Int, size: CGSize, context: GraphicsContext
    ) {
        guard historyLength > 1 else { return }
        let sortedIndices = allOnsets.flatMap { $0.map(\.index) }.sorted()
        var groups: [[Int]] = []
        for index in sortedIndices {
            if let lastValue = groups.last?.last, index - lastValue <= alignmentToleranceSamples {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        for group in groups where group.count > 1 {
            let averageIndex = Double(group.reduce(0, +)) / Double(group.count)
            let x = CGFloat(averageIndex / Double(historyLength - 1)) * size.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                path, with: .color(.white.opacity(0.3)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }
}

private struct SIDVoiceLineupLane: View {
    let channel: SIDVoiceChannel
    let onsets: [SIDLineupOnset]

    private static let labelWidth: CGFloat = 58

    var body: some View {
        HStack(spacing: 0) {
            Text("SID \(channel.chipIndex + 1) · Ch \(channel.voiceIndex + 1)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Self.labelWidth, alignment: .leading)
                .padding(.leading, 6)
            Canvas { context, size in
                drawLane(context: context, size: size)
            }
            .background(Color(white: 0.05))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.12)))
            .padding(.vertical, 1)
        }
    }

    private func drawLane(context: GraphicsContext, size: CGSize) {
        let history = channel.orderedNoteHistory
        guard history.count > 1 else { return }
        let stepX = size.width / CGFloat(history.count - 1)

        var runStart: Int?
        for (index, entry) in history.enumerated() {
            if entry.gate, entry.frequencyHz > 1 {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                drawRun(from: start, to: index - 1, stepX: stepX, size: size, context: context)
                runStart = nil
            }
        }
        if let start = runStart {
            drawRun(from: start, to: history.count - 1, stepX: stepX, size: size, context: context)
        }

        for onset in onsets {
            let x = CGFloat(onset.index) * stepX
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: 0))
            tick.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(tick, with: .color(.yellow.opacity(0.4)), lineWidth: 1)
            context.draw(
                Text(onset.noteName)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.yellow),
                at: CGPoint(x: min(max(x + 2, 12), size.width - 4), y: 8))
        }
    }

    private func drawRun(
        from start: Int, to end: Int, stepX: CGFloat, size: CGSize, context: GraphicsContext
    ) {
        let x0 = CGFloat(start) * stepX
        let x1 = CGFloat(end) * stepX
        let rect = CGRect(x: x0, y: size.height * 0.34, width: max(1, x1 - x0), height: size.height * 0.42)
        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.green.opacity(0.8)))
    }
}
