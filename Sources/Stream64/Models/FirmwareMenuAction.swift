import Foundation

enum FirmwareMenuAction: String, CaseIterable, Identifiable {
    case startTape = "Start Tape"
    case pauseTape = "Pause Tape Playback"
    case resumeTape = "Resume Tape Playback"
    case stopTape = "Stop Tape Playback"
    case saveCartridge = "Save Cartridge"
    case saveDebugLog = "Save Debug Log"
    var id: String { rawValue }
    var categories: [String] {
        switch self {
        case .startTape: return []
        case .pauseTape, .resumeTape, .stopTape: return ["Tape"]
        case .saveCartridge: return ["Cartridge", "C64 Machine", "Power & Reset"]
        case .saveDebugLog: return ["Developer"]
        }
    }
}

@MainActor
enum FirmwareMenuSelection {
    static func highlights(in screen: VT100Screen) -> [String] {
        (0..<screen.rows).map { row in
            String((0..<screen.columns).map { screen.cell(atColumn: $0, row: row) }
                .filter { $0.reversed || ($0.bold && $0.foreground == 7) }.map(\.character))
        }
    }
    static func contains(_ label: String, in screen: VT100Screen, selected: Bool = false) -> Bool {
        for row in 0..<screen.rows {
            let cells = (0..<screen.columns).map { screen.cell(atColumn: $0, row: row) }
            let text = String(cells.map(\.character))
            guard let range = text.range(of: label, options: .caseInsensitive) else { continue }
            if !selected { return true }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let count = text.distance(from: range.lowerBound, to: range.upperBound)
            let nameCells = cells.dropFirst(start).prefix(count)
            if nameCells.allSatisfy({ $0.reversed || ($0.bold && $0.foreground == 7) }) { return true }
        }
        return false
    }
}
