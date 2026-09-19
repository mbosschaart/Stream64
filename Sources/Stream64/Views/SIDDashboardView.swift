import SwiftUI

/// One compact per-chip summary panel — active voice count, master
/// volume, filter mode/cutoff/resonance, and which voices are routed
/// through the filter — a single "at a glance" status readout, unlike
/// every other mode's per-voice detail.
struct SIDDashboardView: View {
    let channels: [SIDVoiceChannel]
    let filterStates: [SIDFilterRegisters]
    var chipIndices: [Int]? = nil

    var body: some View {
        let chipCount = max(filterStates.count, 1)
        GeometryReader { geometry in
            let panelHeight = geometry.size.height / CGFloat(chipCount)
            VStack(spacing: 0) {
                ForEach(0..<chipCount, id: \.self) { chip in
                    SIDChipDashboardPanel(
                        chipIndex: chipIndices?[chip] ?? chip,
                        voices: channels.filter { $0.chipIndex == (chipIndices?[chip] ?? chip) },
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
        GeometryReader { geometry in
            let reference = CGSize(width: 680, height: 230)
            let scale = SIDPanelSizing.scale(in: geometry.size, reference: reference)
            dashboard
                .frame(width: reference.width, height: reference.height)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(white: 0.08))
    }

    private var dashboard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("SID \(chipIndex + 1)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(activeVoiceCount)/\(voices.count) voices active")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 10) {
                    ForEach(voices) { voice in
                        Circle()
                            .fill(voice.registers.gate ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 22, height: 22)
                    }
                }
            }
            .frame(width: 154, alignment: .leading)
            Divider().background(Color.white.opacity(0.2)).frame(height: 132)
            VStack(alignment: .leading, spacing: 12) {
                Text("MASTER VOLUME")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("\(filter.volume)/15")
                    .font(.system(size: 36, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green)
                SIDDashboardBar(value: filter.volume, maxValue: 15, color: .green)
                    .frame(height: 18)
            }
            .frame(width: 150)
            Divider().background(Color.white.opacity(0.2)).frame(height: 132)
            VStack(alignment: .leading, spacing: 10) {
                Text("Filter: \(filterModeLabel)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.cyan)
                Text("\(Int(SIDFilterRegisters.approximateCutoffHz(filter.cutoffValue))) Hz")
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                Text("Resonance \(filter.resonance)/15")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Text(routedLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
