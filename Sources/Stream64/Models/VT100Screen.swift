import Foundation

/// One character cell in a `VT100Screen` grid. Colors are the basic ANSI
/// 0-7 palette (SGR 30-37/40-47); `reversed` swaps foreground/background
/// the same way `RemoteMenuView`'s `MenuScreenCanvas` does for the
/// menu-screen's reverse-video bit.
struct VT100Cell: Equatable {
    var character: Character = " "
    var foreground: UInt8 = 7
    var background: UInt8 = 0
    var bold: Bool = false
    var reversed: Bool = false
}

/// A minimal ANSI/VT100 terminal buffer: a fixed character+attribute grid
/// plus a byte-stream parser that decodes the escape sequences a VT100
/// session sends to redraw itself. This is deliberately self-contained
/// pure logic — no networking — so it is easy to unit-test by feeding it
/// byte sequences and asserting the resulting grid, the same way
/// `UltimateMenuScreen` is a pure decode of the `menu_screen` REST
/// payload. `UltimateTelnetClient` supplies the bytes; `TelnetMonitorView`
/// renders the grid.
///
/// Supports enough of the standard to be usable, not the full spec:
/// cursor positioning/movement (CUP/UP/DOWN/FORWARD/BACK), erase
/// display/line (ED/EL), basic SGR colors, and CR/LF/BS/TAB — the control
/// codes and sequences a menu-driven text UI actually emits.
final class VT100Screen {
    let columns: Int
    let rows: Int
    private(set) var cells: [VT100Cell]
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0

    private enum ParseState {
        case text
        case escape
        case csi
    }
    private var parseState: ParseState = .text
    private var csiParams: [Int] = []
    private var csiCurrentParam = ""

    private var currentForeground: UInt8 = 7
    private var currentBackground: UInt8 = 0
    private var currentBold = false
    private var currentReversed = false

    init(columns: Int = 80, rows: Int = 25) {
        self.columns = columns
        self.rows = rows
        cells = Array(repeating: VT100Cell(), count: columns * rows)
    }

    func cell(atColumn column: Int, row: Int) -> VT100Cell {
        cells[row * columns + column]
    }

    /// Reset the grid, cursor, and attributes to their initial state —
    /// used when a Telnet session (re)connects.
    func reset() {
        cells = Array(repeating: VT100Cell(), count: columns * rows)
        cursorRow = 0
        cursorColumn = 0
        parseState = .text
        csiParams = []
        csiCurrentParam = ""
        resetAttributes()
    }

    /// Feed inbound bytes from the Telnet connection into the parser,
    /// updating the grid/cursor in place.
    func feed(_ data: Data) {
        for byte in data {
            process(byte)
        }
    }

    private func process(_ byte: UInt8) {
        switch parseState {
        case .text: processText(byte)
        case .escape: processEscape(byte)
        case .csi: processCSI(byte)
        }
    }

    private func processText(_ byte: UInt8) {
        switch byte {
        case 0x1B: // ESC
            parseState = .escape
        case 0x0D: // CR
            cursorColumn = 0
        case 0x0A: // LF
            lineFeed()
        case 0x08: // Backspace
            if cursorColumn > 0 { cursorColumn -= 1 }
        case 0x09: // Tab — next stop every 8 columns
            cursorColumn = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        case 0x00...0x07, 0x0B...0x1A: // Other control codes — ignore
            break
        default:
            writeCharacter(Character(Unicode.Scalar(byte)))
        }
    }

    private func writeCharacter(_ character: Character) {
        guard cursorRow < rows, cursorColumn < columns else { return }
        cells[cursorRow * columns + cursorColumn] = VT100Cell(
            character: character,
            foreground: currentForeground,
            background: currentBackground,
            bold: currentBold,
            reversed: currentReversed)
        cursorColumn += 1
        if cursorColumn >= columns {
            cursorColumn = 0
            lineFeed()
        }
    }

    private func lineFeed() {
        if cursorRow + 1 >= rows {
            scrollUp()
        } else {
            cursorRow += 1
        }
    }

    private func scrollUp() {
        cells.removeFirst(columns)
        cells.append(contentsOf: Array(repeating: VT100Cell(), count: columns))
    }

    private func processEscape(_ byte: UInt8) {
        if byte == UInt8(ascii: "[") {
            parseState = .csi
            csiParams = []
            csiCurrentParam = ""
        } else {
            // Unsupported single-character escape (e.g. cursor save/
            // restore) — ignore and resume text parsing.
            parseState = .text
        }
    }

    private func processCSI(_ byte: UInt8) {
        let char = Character(Unicode.Scalar(byte))
        if char.isNumber {
            csiCurrentParam.append(char)
            return
        }
        if char == ";" {
            csiParams.append(Int(csiCurrentParam) ?? 0)
            csiCurrentParam = ""
            return
        }
        // Any other byte is the sequence's final byte.
        csiParams.append(Int(csiCurrentParam) ?? 0)
        csiCurrentParam = ""
        applyCSI(finalByte: char, params: csiParams)
        parseState = .text
    }

    private func applyCSI(finalByte: Character, params: [Int]) {
        func param(_ index: Int, default value: Int) -> Int {
            guard index < params.count, params[index] > 0 else { return value }
            return params[index]
        }
        switch finalByte {
        case "H", "f": // Cursor Position (1-based)
            cursorRow = min(rows - 1, max(0, param(0, default: 1) - 1))
            cursorColumn = min(columns - 1, max(0, param(1, default: 1) - 1))
        case "A": // Cursor Up
            cursorRow = max(0, cursorRow - param(0, default: 1))
        case "B": // Cursor Down
            cursorRow = min(rows - 1, cursorRow + param(0, default: 1))
        case "C": // Cursor Forward
            cursorColumn = min(columns - 1, cursorColumn + param(0, default: 1))
        case "D": // Cursor Back
            cursorColumn = max(0, cursorColumn - param(0, default: 1))
        case "J": // Erase Display
            eraseDisplay(mode: params.first ?? 0)
        case "K": // Erase Line
            eraseLine(mode: params.first ?? 0)
        case "m": // SGR
            applySGR(params)
        default:
            break // Unsupported sequence — ignore.
        }
    }

    private func eraseDisplay(mode: Int) {
        let cursorIndex = cursorRow * columns + cursorColumn
        switch mode {
        case 1: // Start of screen to cursor
            for i in 0...min(cursorIndex, cells.count - 1) { cells[i] = VT100Cell() }
        case 2, 3: // Entire screen
            cells = Array(repeating: VT100Cell(), count: columns * rows)
        default: // 0: cursor to end of screen
            for i in cursorIndex..<cells.count { cells[i] = VT100Cell() }
        }
    }

    private func eraseLine(mode: Int) {
        let rowStart = cursorRow * columns
        let rowEnd = rowStart + columns
        switch mode {
        case 1: // Start of line to cursor
            for i in rowStart...(rowStart + cursorColumn) where i < rowEnd { cells[i] = VT100Cell() }
        case 2: // Entire line
            for i in rowStart..<rowEnd { cells[i] = VT100Cell() }
        default: // 0: cursor to end of line
            for i in (rowStart + cursorColumn)..<rowEnd { cells[i] = VT100Cell() }
        }
    }

    private func applySGR(_ codes: [Int]) {
        guard !codes.isEmpty else {
            resetAttributes()
            return
        }
        for code in codes {
            switch code {
            case 0: resetAttributes()
            case 1: currentBold = true
            case 7: currentReversed = true
            case 22: currentBold = false
            case 27: currentReversed = false
            case 30...37: currentForeground = UInt8(code - 30)
            case 39: currentForeground = 7
            case 40...47: currentBackground = UInt8(code - 40)
            case 49: currentBackground = 0
            default: break
            }
        }
    }

    private func resetAttributes() {
        currentForeground = 7
        currentBackground = 0
        currentBold = false
        currentReversed = false
    }
}
