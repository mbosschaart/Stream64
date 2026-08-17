import SwiftUI

/// One compact per-chip summary panel — active voice count, master
/// volume, filter mode/cutoff/resonance, and which voices are routed
/// through the filter — a single "at a glance" status readout, unlike
/// every other mode's per-voice detail.
struct SIDDashboardView: View {
    let channels: [SIDVoiceChannel]
    let filterStates: [SIDFilterRegisters]

    var body: some View {
        let chipCount = max(filterStates.count, 1)
        GeometryReader { geometry in
            let panelHeight = geometry.size.height / CGFloat(chipCount)
            VStack(spacing: 0) {
                ForEach(0..<chipCount, id: \.self) { chip in
                    SIDChipDashboardPanel(
                        chipIndex: chip,
                        voices: channels.filter { $0.chipIndex == chip },
                        filter: filterStates.indices.contains(chip) ? filterStates[chip] : SIDFilterRegisters())
                        .frame(height: panelHeight)
                }
            }
        }
        .background(Color.black)
    }
}

private struct SIDChipDashboardPanel: View {
    let chipIndex: Int
    let voices: [SIDVoiceChannel]
    let filter: SIDFilterRegisters

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SID \(chipIndex + 1)")
                    .font(.title3).bold()
                    .foregroundStyle(.white)
                Text("\(activeVoiceCount)/\(voices.count) voices active")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 6) {
                    ForEach(voices) { voice in
                        Circle()
                            .fill(voice.registers.gate ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .frame(width: 132, alignment: .leading)
            Divider().background(Color.white.opacity(0.2)).frame(height: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text("Master Volume")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                SIDDashboardBar(value: filter.volume, maxValue: 15, color: .green)
                    .frame(height: 10)
                Text("\(filter.volume)/15")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            // Leave the filter readout a stable, wider lane so its labels do
            // not reflow as the dashboard updates.
            .frame(width: 112)
            Divider().background(Color.white.opacity(0.2)).frame(height: 60)
            VStack(alignment: .leading, spacing: 6) {
                Text("Filter: \(filterModeLabel)")
                    .font(.callout).bold()
                    .foregroundStyle(.cyan)
                Text("\(Int(SIDFilterRegisters.approximateCutoffHz(filter.cutoffValue))) Hz · Res \(filter.resonance)/15")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Text(routedLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    private var activeVoiceCount: Int {
        voices.filter { $0.registers.gate }.count
    }

    private var filterModeLabel: String {
        var parts: [String] = []
        if filter.lowPassEnabled { parts.append("LP") }
        if filter.bandPassEnabled { parts.append("BP") }
        if filter.highPassEnabled { parts.append("HP") }
        return parts.isEmpty ? "Off" : parts.joined(separator: "+")
    }

    private var routedLabel: String {
        let routed = (0..<3).filter { filter.voiceRouted($0) }.map { "Ch\($0 + 1)" }
        return routed.isEmpty ? "No voices routed" : "Routed: " + routed.joined(separator: ", ")
    }
}

private struct SIDDashboardBar: View {
    let value: Int
    let maxValue: Int
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(value) / CGFloat(maxValue))
            }
        }
    }
}
