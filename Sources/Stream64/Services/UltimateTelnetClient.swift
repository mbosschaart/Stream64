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

    func connect(host: String, port: UInt16 = 23) {
        disconnect()
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
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
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onData?(data)
            }
            if let error {
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.onStateChange?(.cancelled)
                return
            }
            if let connection {
                self.receive(on: connection)
            }
        }
    }
}
