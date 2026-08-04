import Foundation
import Network

/// TCP client for the Ultimate's Telnet server (port 23, VT100).
///
/// The on-device menu system and Machine Code Monitor are native firmware
/// UI, not REST resources — Ultimate's own manual documents Telnet as the
/// supported way to drive that UI remotely ("it is possible to connect...
/// using a VT-100 terminal program on the Telnet port (port 23). This
/// gives the possibility to control the machine remotely..."). This client
/// just moves bytes; `VT100Screen` decodes what comes back and
/// `TelnetMonitorView` sends keystrokes as their VT100 byte encoding.
final class UltimateTelnetClient {
    enum State: Equatable {
        case connecting
        case ready
        case failed(String)
        case cancelled
    }

    /// Fires on the receiver's private queue with raw inbound bytes.
    /// Callers hop to the main actor themselves.
    var onData: ((Data) -> Void)?
    var onStateChange: ((State) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "ultimate-telnet-client")
    private var connectionGeneration: UInt64 = 0
    /// Strips Telnet protocol-negotiation bytes (IAC/0xFF sequences)
    /// before `onData` ever sees them — confirmed against a real
    /// device's raw byte capture that the Ultimate's Telnet server sends
    /// `IAC DONT LINEMODE` + `IAC WILL ECHO` immediately on connect.
    /// Without this, those framing bytes leak into `VT100Screen` as if
    /// they were displayable text/PETSCII graphics, showing up as a
    /// handful of stray characters at the very start of the screen.
    private var iacFilter = TelnetIACFilter()

    func connect(host: String, port: UInt16 = 23) {
        disconnect()
        iacFilter = TelnetIACFilter()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard self.isCurrent(connection, generation: generation) else { return }
            switch state {
            case .ready:
                self.onStateChange?(.ready)
            case .failed(let error):
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        onStateChange?(.connecting)
        receive(on: connection)
    }

    func disconnect() {
        connectionGeneration &+= 1
        connection?.cancel()
        connection = nil
    }

    /// Send raw bytes — a keystroke's ASCII/VT100 escape-sequence encoding
    /// — to the remote session.
    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 8192
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection,
                  self.isCurrent(connection) else { return }
            if let data, !data.isEmpty {
                let filtered = self.iacFilter.filter(data)
                if !filtered.isEmpty {
                    self.onData?(filtered)
                }
            }
            if let error {
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.onStateChange?(.cancelled)
                return
            }
            self.receive(on: connection)
        }
    }

    private func isCurrent(
        _ connection: NWConnection,
        generation: UInt64? = nil
    ) -> Bool {
        guard self.connection === connection else { return false }
        if let generation {
            return connectionGeneration == generation
        }
        return true
    }
}

/// A minimal, stateful Telnet IAC (0xFF) protocol-negotiation filter.
/// `IAC WILL/WONT/DO/DONT <option>` (3 bytes), `IAC SB ... IAC SE`
/// (variable-length subnegotiation), and other 2-byte IAC commands
/// (NOP/DM/BRK/IP/AO/AYT/EC/EL/GA, etc.) are all consumed and dropped —
/// this client never negotiates any Telnet option, it just needs to not
/// leak the negotiation bytes themselves into the VT100 byte stream.
/// `IAC IAC` (the escape sequence for a literal 0xFF byte in the actual
/// data) is unescaped and passed through. Stateful across calls to
/// `filter(_:)` so a sequence split across two TCP reads still decodes
/// correctly, exactly like `VT100Screen`'s own byte-at-a-time parser.
final class TelnetIACFilter {
    private enum State {
        case normal
        case sawIAC
        case sawWillWontDoDont
        case subnegotiation
        case subnegotiationSawIAC
    }
    private var state: State = .normal

    func filter(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .normal:
                if byte == 0xFF {
                    state = .sawIAC
                } else {
                    output.append(byte)
                }
            case .sawIAC:
                switch byte {
                case 0xFF: // IAC IAC — literal 0xFF in the data.
                    output.append(0xFF)
                    state = .normal
                case 0xFB, 0xFC, 0xFD, 0xFE: // WILL, WONT, DO, DONT — one option byte follows.
                    state = .sawWillWontDoDont
                case 0xFA: // SB — subnegotiation, runs until IAC SE.
                    state = .subnegotiation
                default: // NOP/DM/BRK/IP/AO/AYT/EC/EL/GA — no further bytes.
                    state = .normal
                }
            case .sawWillWontDoDont:
                state = .normal // Consume the option byte; sequence complete.
            case .subnegotiation:
                if byte == 0xFF {
                    state = .subnegotiationSawIAC
                }
            case .subnegotiationSawIAC:
                state = (byte == 0xF0) ? .normal : .subnegotiation // 0xF0 = SE
            }
        }
        return output
    }
}
