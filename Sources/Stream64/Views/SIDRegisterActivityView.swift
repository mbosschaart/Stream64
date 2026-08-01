import SwiftUI

/// A compact heatmap of the SID's own actual register bytes — not the
/// derived audio/envelope state every other mode reconstructs from them.
/// Each cell is one of the ~25 writable registers per chip, labeled by
/// mnemonic and fading out after being written, the same "recent
/// activity" idea `MemoryMapView` uses for the full 64K address space,
/// just zoomed in to the SID's own tiny address range with meaningful
/// names instead of raw addresses.
struct SIDRegisterActivityView: View {
    let activity: SIDRegisterActivity

    private static let refreshInterval: Double = 1.0 / 20.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { context in
            VStack(spacing: 14) {
                ForEach(Array(activity.lastWrite.enumerated()), id: \.offset) { chipIndex, lastWrite in
                    SIDRegisterActivityChipGrid(
                        chipIndex: chipIndex, lastWrite: lastWrite, now: context.date)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.black)
    }
}

private struct SIDRegisterActivityChipGrid: View {
    let chipIndex: Int
    let lastWrite: [Date?]
    let now: Date

    /// How long a cell stays lit after being written — longer than
    /// `MemoryMapView`'s 150ms default, since individual SID register
    /// writes happen far less densely than a full 6510/VIC bus trace and
    /// a quick flash would be easy to miss entirely.
    private static let fadeDuration: Double = 0.6
    private static let columns = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SID \(chipIndex + 1)")
                .font(.caption).bold()
                .foregroundStyle(.white.opacity(0.7))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: Self.columns),
                spacing: 4
            ) {
                ForEach(0..<SIDRegisterActivity.registerCount, id: \.self) { offset in
                    SIDRegisterActivityCell(
                        label: SIDRegisterActivity.mnemonics[offset],
                        intensity: intensity(forOffset: offset))
                }
            }
        }
    }

    private func intensity(forOffset offset: Int) -> Double {
        guard lastWrite.indices.contains(offset), let time = lastWrite[offset] else { return 0 }
        let age = now.timeIntervalSince(time)
        guard age >= 0, age < Self.fadeDuration else { return 0 }
        let t = 1 - age / Self.fadeDuration
        return t * t // Squared falloff — matches MemoryMapView's fade curve.
    }
}

private struct SIDRegisterActivityCell: View {
    let label: String
    let intensity: Double

    var body: some View {
        Text(label)
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6 + intensity * 0.4))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.orange.opacity(intensity * 0.85))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.12)))
            .cornerRadius(3)
    }
}
