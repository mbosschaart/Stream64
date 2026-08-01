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
        /// Mid-`ESC ( ` or `ESC ) ` — the next byte designates which
        /// character set G0 (`slot == 0`) or G1 (`slot == 1`) refers to.
        case scs(slot: Int)
    }
    private var parseState: ParseState = .text
    private var csiParams: [Int] = []
    private var csiCurrentParam = ""

    private var currentForeground: UInt8 = 7
    private var currentBackground: UInt8 = 0
    private var currentBold = false
    private var currentReversed = false

    /// Whether G0/G1 are currently designated as the DEC Special
    /// Graphics line-drawing set (`ESC ( 0` / `ESC ) 0`) rather than
    /// plain ASCII (`ESC ( B` / `ESC ) B`, or the power-on default).
    /// `shiftedToG1` tracks which of the two is *active*, toggled by SO
    /// (0x0E, shift out to G1) / SI (0x0F, shift in to G0) — see
    /// `VT100LineDrawing` for what this actually changes and why it's
    /// needed at all.
    private var g0IsLineDrawing = false
    private var g1IsLineDrawing = false
    private var shiftedToG1 = false
    private var lineDrawingActive: Bool { shiftedToG1 ? g1IsLineDrawing : g0IsLineDrawing }

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
        g0IsLineDrawing = false
        g1IsLineDrawing = false
        shiftedToG1 = false
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
        case .scs(let slot): processSCS(byte, slot: slot)
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
        case 0x09: // Tab — next stop every 8 columns
            cursorColumn = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        case 0x0E: // SO — shift out to G1
            shiftedToG1 = true
        case 0x0F: // SI — shift in to G0
            shiftedToG1 = false
        case 0x00...0x1F, 0x80...0x9F: // PETSCII control-code range
            applyPETSCIIControlCode(byte)
        default:
            let glyph = lineDrawingActive ? VT100LineDrawing.character(for: byte) : nil
            writeCharacter(glyph ?? PETSCIIGlyph.character(for: byte))
        }
    }

    /// Applies a raw PETSCII control code (0x00-0x1F, 0x80-0x9F) received
    /// outside a VT100 escape/CSI sequence. In practice the Ultimate's
    /// Telnet server sends genuine VT100 CSI sequences for cursor
    /// movement and SGR for color — that's the entire point of
    /// advertising VT100 support — so these mostly won't be hit; this
    /// exists as a defensive fallback so an unexpected raw PETSCII byte
    /// degrades gracefully (moves the cursor/changes color, as intended)
    /// instead of being silently dropped or, worse, written into a cell
    /// as whatever arbitrary Unicode control-character glyph that byte
    /// happens to correspond to. This range (0x00-0x1F, 0x80-0x9F) has
    /// no legitimate meaning as plain-text ASCII either way, unlike the
    /// printable range `PETSCIIGlyph` handles — see its doc comment.
    ///
    /// PETSCII's 16-color palette doesn't fit the 8 basic ANSI colors
    /// this screen model supports; colors without a good match are
    /// approximated to their nearest neighbor rather than left
    /// unhandled.
    private func applyPETSCIIControlCode(_ byte: UInt8) {
        switch byte {
        case 0x05: currentForeground = 7 // WHITE
        case 0x08, 0x14: if cursorColumn > 0 { cursorColumn -= 1 } // BS / DEL
        case 0x11: cursorRow = min(rows - 1, cursorRow + 1) // CURSOR DOWN
        case 0x12: currentReversed = true // REVERSE ON
        case 0x13: cursorRow = 0; cursorColumn = 0 // HOME
        case 0x1C: currentForeground = 1 // RED
        case 0x1D: cursorColumn = min(columns - 1, cursorColumn + 1) // CURSOR RIGHT
        case 0x1E: currentForeground = 2 // GREEN
        case 0x1F: currentForeground = 4 // BLUE
        case 0x81: currentForeground = 3 // ORANGE (approx: yellow)
        case 0x90: currentForeground = 0 // BLACK
        case 0x91: cursorRow = max(0, cursorRow - 1) // CURSOR UP
        case 0x92: currentReversed = false // REVERSE OFF
        case 0x93: // CLEAR
            cursorRow = 0
            cursorColumn = 0
            cells = Array(repeating: VT100Cell(), count: columns * rows)
        case 0x95: currentForeground = 1 // BROWN (approx: red)
        case 0x96: currentForeground = 1 // PINK/LIGHT RED (approx: red)
        case 0x97: currentForeground = 0 // DARK GRAY (approx: black)
        case 0x98: currentForeground = 7 // MEDIUM GRAY (approx: white)
        case 0x99: currentForeground = 2 // LIGHT GREEN (approx: green)
        case 0x9A: currentForeground = 4 // LIGHT BLUE (approx: blue)
        case 0x9B: currentForeground = 7 // LIGHT GRAY (approx: white)
        case 0x9C: currentForeground = 5 // PURPLE
        case 0x9D: cursorColumn = max(0, cursorColumn - 1) // CURSOR LEFT
        case 0x9E: currentForeground = 3 // YELLOW
        case 0x9F: currentForeground = 6 // CYAN
        default: break // Undefined/input-only (STOP, RUN, F1-F8, etc.) — no display effect.
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
        switch byte {
        case UInt8(ascii: "["):
            parseState = .csi
            csiParams = []
            csiCurrentParam = ""
        case UInt8(ascii: "("):
            parseState = .scs(slot: 0) // designate G0
        case UInt8(ascii: ")"):
            parseState = .scs(slot: 1) // designate G1
        default:
            // Unsupported single-character escape (e.g. cursor save/
            // restore) — ignore and resume text parsing.
            parseState = .text
        }
    }

    /// Select Character Set (`ESC ( X` / `ESC ) X`) — `X == "0"`
    /// designates the DEC Special Graphics line-drawing set for the
    /// given slot; anything else (conventionally `"B"`, US ASCII)
    /// designates plain text. This is how a real VT100 application
    /// switches into line-drawing mode for box borders without needing
    /// any non-ASCII bytes at all — confirmed against a real device,
    /// whose Telnet menu draws its borders exactly this way rather than
    /// with raw PETSCII graphics bytes (see `HANDOVER.md` §14 for the
    /// full story of the two wrong guesses that preceded this).
    private func processSCS(_ byte: UInt8, slot: Int) {
        let isLineDrawing = byte == UInt8(ascii: "0")
        if slot == 0 {
            g0IsLineDrawing = isLineDrawing
        } else {
            g1IsLineDrawing = isLineDrawing
        }
        parseState = .text
    }

    /// Per the ANSI/ECMA-48 CSI grammar, `ESC [` is followed by parameter
    /// bytes (0x30-0x3F — digits, `;`, and marker bytes like `?`/`<`/`=`/
    /// `>`), then optional intermediate bytes (0x20-0x2F), then exactly
    /// one final byte (0x40-0x7E) that ends the sequence. The previous
    /// version of this parser treated *any* non-digit, non-`;` byte as
    /// the final byte — so a common, standard sequence like `ESC[?25l`
    /// (DEC private mode: hide cursor) would end the CSI sequence at
    /// `?` and then write the leftover `"25l"` onto the screen as
    /// literal text. Firmware that toggles cursor visibility or the
    /// alternate screen buffer (`ESC[?1049h`/`l`) this way — every
    /// cursor blink, for some firmware — would inject a few stray
    /// characters (and an unwanted cursor/line-feed side effect from
    /// each one, since digits/`l`/`h` aren't `;`) *every single time*,
    /// which compounds into a garbled or fully scrolled-past-blank
    /// screen fast. See `HANDOVER.md` §14 for the firmware-version
    /// difference that surfaced this.
    private func processCSI(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            csiCurrentParam.append(Character(UnicodeScalar(byte)))
        case UInt8(ascii: ";"):
            csiParams.append(Int(csiCurrentParam) ?? 0)
            csiCurrentParam = ""
        case 0x3C...0x3F, 0x20...0x2F:
            // Marker bytes (`<`, `=`, `>`, `?`) and intermediate bytes —
            // consumed as part of the sequence, but not a parameter
            // digit and not the final byte. `applyCSI` doesn't implement
            // any DEC private modes, so sequences using these end up
            // no-ops either way; what matters is consuming them *here*
            // rather than ending the sequence early.
            break
        case 0x40...0x7E:
            csiParams.append(Int(csiCurrentParam) ?? 0)
            csiCurrentParam = ""
            applyCSI(finalByte: Character(UnicodeScalar(byte)), params: csiParams)
            parseState = .text
        default:
            // Malformed/unexpected byte — bail out to plain text
            // parsing rather than getting stuck waiting for a final
            // byte that will never come.
            parseState = .text
        }
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

/// The DEC "Special Graphics and Line Drawing" character set — a
/// standard, universal VT100 alternate character set (nothing to do with
/// PETSCII), selected via `ESC ( 0`/`ESC ) 0` and invoked via SO/SI. Only
/// remaps the lowercase-letter-shaped byte range (0x5F-0x7E); anything
/// else falls back to plain ASCII/PETSCII handling as if line drawing
/// weren't active.
///
/// The 5 horizontal scan-line-height variants (`o`,`p`,`q`,`r`,`s`,
/// meant to draw a horizontal line at slightly different vertical
/// positions within the cell — a VT100 quirk, not something a modern
/// monospace font can usefully distinguish) are all approximated with a
/// single centered "─", since no common font renders 5 visually distinct
/// heights for this anyway.
private enum VT100LineDrawing {
    static func character(for byte: UInt8) -> Character? {
        switch byte {
        case 0x5F: return " " // blank
        case 0x60: return "◆"
        case 0x61: return "▒"
        case 0x66: return "°"
        case 0x67: return "±"
        case 0x6A: return "┘"
        case 0x6B: return "┐"
        case 0x6C: return "┌"
        case 0x6D: return "└"
        case 0x6E: return "┼"
        case 0x6F, 0x70, 0x71, 0x72, 0x73: return "─"
        case 0x74: return "├"
        case 0x75: return "┤"
        case 0x76: return "┴"
        case 0x77: return "┬"
        case 0x78: return "│"
        case 0x79: return "≤"
        case 0x7A: return "≥"
        case 0x7B: return "π"
        case 0x7C: return "≠"
        case 0x7D: return "£"
        case 0x7E: return "·"
        default: return nil // Not remapped — plain ASCII, even while active.
        }
    }
}
