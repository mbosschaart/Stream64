import SwiftUI

/// Dim blue records every write; orange flashes only when the byte changes.
/// The engine's existing visible-window updates drive decay, with no extra timer.
struct SIDRegisterActivityView: View {
    let activity: SIDRegisterActivity
    var chipIndices: [Int]? = nil

    var body: some View {
        GeometryReader { geometry in
            let chips = activity.lastWrite.count
            let horizontal = chips > 1 && geometry.size.width > geometry.size.height * 1.4
            let columns = horizontal ? chips : 1
            let rows = horizontal ? 1 : chips
            let reference = CGSize(width: CGFloat(columns) * 520,
                                   height: CGFloat(rows) * 310 + 30)
            let scale = SIDPanelSizing.scale(in: geometry.size, reference: reference)
            VStack(spacing: 8) {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(0..<rows, id: \.self) { row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { column in
                                chipGrid(row * columns + column)
                            }
                        }
                    }
                }
                Text("BLUE · WRITE     ORANGE · VALUE CHANGE")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(10)
            .frame(width: reference.width, height: reference.height)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.black)
    }

    private func chipGrid(_ chip: Int) -> some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 8) {
            Text("SID \((chipIndices?[chip] ?? chip) + 1)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(0..<5, id: \.self) { row in
                    GridRow {
                        ForEach(0..<5, id: \.self) { column in
                            let offset = row * 5 + column
                            SIDRegisterActivityCell(
                                label: SIDRegisterActivity.mnemonics[offset],
                                value: activity.values[chip][offset],
                                write: activity.intensity(chipIndex: chip, offset: offset, at: now, changes: false),
                                change: activity.intensity(chipIndex: chip, offset: offset, at: now, changes: true))
                        }
                    }
                }
            }
        }
        .frame(width: 496, height: 296)
    }
}

private struct SIDRegisterActivityCell: View {
    let label: String
    let value: UInt8?
    let write: Double
    let change: Double

    var body: some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
            Text(value.map { String(format: "$%02X", Int($0)) } ?? "—")
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(width: 95, height: 48)
        .background(Color(white: 0.035))
        .background(Color.black)
        .overlay(RoundedRectangle(cornerRadius: 4).fill(Color.cyan.opacity(write * 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(change * 0.65)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange.opacity(0.10 + change * 0.8)))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("\(label), \(value.map { String($0) } ?? "unknown")")
    }
}
