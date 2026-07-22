import Foundation
import Network

actor UltimateFTPClient {
    struct Reply: Equatable {
        let code: Int
        let lines: [String]
        var message: String { lines.joined(separator: "\n") }
    }

    enum FTPError: LocalizedError {
        case connection(String)
        case reply(Reply)
        case command(String, Reply)
        case malformedReply(String)
        case listing(String)

        var errorDescription: String? {
            switch self {
            case .connection(let message): return "FTP connection failed: \(message)"
            case .reply(let reply): return "FTP \(reply.code): \(reply.message)"
            case .command(let command, let reply):
                return "FTP \(reply.code) for \(command): \(reply.message)"
            case .malformedReply(let line): return "Malformed FTP response: \(line)"
            case .listing(let line): return "Unrecognized directory entry: \(line)"
            }
        }
    }

    let device: UltimateDevice
    private let timeout: TimeInterval

    init(device: UltimateDevice, timeout: TimeInterval = 10) {
        self.device = device
        self.timeout = timeout
    }

    func testConnection() async throws {
        try await withSession { _ in () }
    }

    func list(_ path: ManagedPath) async throws -> [FilesystemItem] {
        do {
            return try await listOnce(path)
        } catch {
            try await Task.sleep(for: .milliseconds(250))
            return try await listOnce(path)
        }
    }

    private func listOnce(_ path: ManagedPath) async throws -> [FilesystemItem] {
        try await withSession { session in
            do {
                let data = try await session.dataCommand("MLSD \(try Self.commandPath(path))")
                return try Self.parseMLSD(data, endpoint: .ultimate(device.id), parent: path)
            } catch {
                let data = try await session.dataCommand("LIST \(try Self.commandPath(path))")
                return try Self.parseLIST(data, endpoint: .ultimate(device.id), parent: path)
            }
        }
    }

    func stat(_ path: ManagedPath) async throws -> FilesystemItem? {
        let items = try await list(path.parent)
        return items.first { $0.path == path }
    }

    func makeDirectory(_ path: ManagedPath) async throws {
        try await withSession { session in
            try await session.expectSuccess("MKD \(try Self.commandPath(path))")
        }
    }

    func rename(_ source: ManagedPath, to destination: ManagedPath) async throws {
        try await withSession { session in
            let first = try await session.command("RNFR \(try Self.commandPath(source))")
            guard first.code == 350 else {
                throw FTPError.command("RNFR", first)
            }
            try await session.expectSuccess("RNTO \(try Self.commandPath(destination))")
        }
    }

    func deleteFile(_ path: ManagedPath) async throws {
        try await withSession { session in
            try await session.expectSuccess("DELE \(try Self.commandPath(path))")
        }
    }

    func deleteDirectory(_ path: ManagedPath) async throws {
        try await withSession { session in
            try await session.expectSuccess("RMD \(try Self.commandPath(path))")
        }
    }

    func download(_ remotePath: ManagedPath, to localURL: URL,
                  progress: @escaping FileProgressHandler) async throws {
        try await withSession { session in
            let sizeReply = try? await session.command(
                "SIZE \(try Self.commandPath(remotePath))")
            let total = sizeReply.flatMap { reply -> Int64? in
                guard reply.code == 213 else { return nil }
                return Int64(reply.lines.last?.split(separator: " ").last ?? "")
            }
            try await session.download(
                "RETR \(try Self.commandPath(remotePath))",
                to: localURL, total: total, progress: progress)
        }
    }

    func upload(_ localURL: URL, to remotePath: ManagedPath,
                progress: @escaping FileProgressHandler) async throws {
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(values.fileSize ?? 0)
        try await withSession { session in
            try await session.upload(
                "STOR \(try Self.commandPath(remotePath))",
                from: localURL, total: total, progress: progress)
        }
    }

    private func withSession<T>(
        _ operation: (FTPControlSession) async throws -> T
    ) async throws -> T {
        let session = FTPControlSession(
            host: device.host,
            port: UInt16(clamping: device.effectiveFTPPort),
            username: device.effectiveFTPUsername,
            password: device.password,
            timeout: timeout)
        return try await withTaskCancellationHandler {
            try await session.connectAndLogin()
            do {
                let value = try await operation(session)
                await session.quit()
                return value
            } catch {
                session.close()
                throw error
            }
        } onCancel: {
            session.close()
        }
    }

    static func commandPath(_ path: ManagedPath) throws -> String {
        guard !path.rawValue.contains("\r"), !path.rawValue.contains("\n"),
              !path.rawValue.contains("\0"),
              path.rawValue.hasPrefix("/"),
              !path.rawValue.split(separator: "/").contains("..") else {
            throw FileSystemError.unsafePath
        }
        return path.rawValue
    }

    static func parseMLSD(
        _ data: Data, endpoint: FileEndpoint, parent: ManagedPath
    ) throws -> [FilesystemItem] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FTPError.listing("Non-UTF8 MLSD response")
        }
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let separator = line.firstIndex(of: " ") else { return nil }
            let factsText = line[..<separator]
            let name = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            var facts: [String: String] = [:]
            for fact in factsText.split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { facts[pair[0].lowercased()] = pair[1] }
            }
            let type = facts["type"]?.lowercased() ?? "file"
            if type == "cdir" || type == "pdir" { return nil }
            let directory = type == "dir"
            let modified = facts["modify"].flatMap(parseFTPDate)
            return FilesystemItem(
                endpoint: endpoint,
                path: parent.appending(name),
                kind: .classify(name: name, isDirectory: directory),
                size: directory ? nil : facts["size"].flatMap(Int64.init),
                modified: modified)
        }
    }

    static func parseLIST(
        _ data: Data, endpoint: FileEndpoint, parent: ManagedPath
    ) throws -> [FilesystemItem] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FTPError.listing("Non-UTF8 LIST response")
        }
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let fields = raw.split(
                maxSplits: 8, omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace)
            guard fields.count >= 9 else { return nil }
            let name = String(fields[8])
            guard name != ".", name != ".." else { return nil }
            let directory = fields[0].first == "d"
            return FilesystemItem(
                endpoint: endpoint, path: parent.appending(name),
                kind: .classify(name: name, isDirectory: directory),
                size: directory ? nil : Int64(fields[4]),
                modified: nil)
        }
    }

    private static func parseFTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(value.prefix(14)))
    }
}

private final class FTPControlSession: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "Stream64.FTP")
    private var control: NWConnection?
    private var activeDataConnection: NWConnection?
    private var buffer = Data()

    init(host: String, port: UInt16, username: String,
         password: String, timeout: TimeInterval) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.timeout = timeout
    }

    func connectAndLogin() async throws {
        control = try await openConnection(port: port)
        let greeting = try await readReply()
        guard greeting.code == 220 else { throw UltimateFTPClient.FTPError.reply(greeting) }
        let user = try await command("USER \(username)")
        if user.code == 331 {
            let pass = password.isEmpty ? "stream64@" : password
            try await expectSuccess("PASS \(pass)")
        } else if !(200...299).contains(user.code) {
            throw UltimateFTPClient.FTPError.reply(user)
        }
        try await expectSuccess("TYPE I")
        _ = try? await command("OPTS UTF8 ON")
    }

    func command(_ text: String) async throws -> UltimateFTPClient.Reply {
        guard let control else { throw FileSystemError.notConnected }
        try await send(Data("\(text)\r\n".utf8), on: control)
        return try await readReply()
    }

    func expectSuccess(_ text: String) async throws {
        let reply = try await command(text)
        guard (200...299).contains(reply.code) else {
            throw UltimateFTPClient.FTPError.command(
                text.split(separator: " ").first.map(String.init) ?? text,
                reply)
        }
    }

    func dataCommand(_ text: String) async throws -> Data {
        let dataConnection = try await passiveConnection()
        let preliminary = try await command(text)
        guard (100...199).contains(preliminary.code) else {
            dataConnection.cancel()
            throw UltimateFTPClient.FTPError.command(
                text.split(separator: " ").first.map(String.init) ?? text,
                preliminary)
        }
        let data = try await receiveAll(from: dataConnection)
        dataConnection.cancel()
        activeDataConnection = nil
        let final = try await readReply()
        guard (200...299).contains(final.code) else {
            throw UltimateFTPClient.FTPError.reply(final)
        }
        return data
    }

    func download(_ commandText: String, to url: URL, total: Int64?,
                  progress: @escaping FileProgressHandler) async throws {
        let dataConnection = try await passiveConnection()
        let preliminary = try await command(commandText)
        guard (100...199).contains(preliminary.code) else {
            dataConnection.cancel()
            throw UltimateFTPClient.FTPError.command(
                commandText.split(separator: " ").first.map(String.init)
                    ?? commandText,
                preliminary)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var completed: Int64 = 0
        while true {
            let packet = try await receiveChunk(from: dataConnection)
            guard let chunk = packet.data, !chunk.isEmpty else {
                if packet.complete { break }
                continue
            }
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            completed += Int64(chunk.count)
            await progress(completed, total)
            if packet.complete { break }
        }
        dataConnection.cancel()
        activeDataConnection = nil
        let final = try await readReply()
        guard (200...299).contains(final.code) else {
            throw UltimateFTPClient.FTPError.reply(final)
        }
    }

    func upload(_ commandText: String, from url: URL, total: Int64,
                progress: @escaping FileProgressHandler) async throws {
        let dataConnection = try await passiveConnection()
        let preliminary = try await command(commandText)
        guard (100...199).contains(preliminary.code) else {
            dataConnection.cancel()
            throw UltimateFTPClient.FTPError.command(
                commandText.split(separator: " ").first.map(String.init)
                    ?? commandText,
                preliminary)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var completed: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try await send(chunk, on: dataConnection)
            completed += Int64(chunk.count)
            await progress(completed, total)
        }
        try await finishSending(on: dataConnection)
        dataConnection.cancel()
        activeDataConnection = nil
        let final = try await readReply()
        guard (200...299).contains(final.code) else {
            throw UltimateFTPClient.FTPError.reply(final)
        }
    }

    func quit() async {
        _ = try? await command("QUIT")
        close()
    }

    func close() {
        activeDataConnection?.cancel()
        activeDataConnection = nil
        control?.cancel()
        control = nil
    }

    private func passiveConnection() async throws -> NWConnection {
        let epsv = try await command("EPSV")
        var dataPort: UInt16?
        if epsv.code == 229,
           let start = epsv.message.lastIndex(of: "("),
           let end = epsv.message.lastIndex(of: ")") {
            let content = epsv.message[epsv.message.index(after: start)..<end]
            dataPort = UInt16(content.split(separator: "|").last ?? "")
        }
        if dataPort == nil {
            let pasv = try await command("PASV")
            guard pasv.code == 227,
                  let start = pasv.message.lastIndex(of: "("),
                  let end = pasv.message.lastIndex(of: ")") else {
                throw UltimateFTPClient.FTPError.reply(pasv)
            }
            let values = pasv.message[pasv.message.index(after: start)..<end]
                .split(separator: ",").compactMap { UInt16($0) }
            guard values.count == 6 else {
                throw UltimateFTPClient.FTPError.malformedReply(pasv.message)
            }
            dataPort = values[4] * 256 + values[5]
        }
        guard let dataPort else {
            throw UltimateFTPClient.FTPError.connection("No passive port")
        }
        let connection = try await openConnection(port: dataPort)
        activeDataConnection = connection
        return connection
    }

    private func readReply() async throws -> UltimateFTPClient.Reply {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw UltimateFTPClient.FTPError.malformedReply(first)
        }
        var lines = [first]
        if first.count > 3, first[first.index(first.startIndex, offsetBy: 3)] == "-" {
            let terminator = "\(code) "
            while true {
                let line = try await readLine()
                lines.append(line)
                if line.hasPrefix(terminator) { break }
            }
        }
        return UltimateFTPClient.Reply(code: code, lines: lines)
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let line = buffer[..<range.lowerBound]
                buffer.removeSubrange(..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            guard let control else {
                throw UltimateFTPClient.FTPError.connection("Control connection closed")
            }
            let packet = try await receiveChunk(from: control)
            if let chunk = packet.data, !chunk.isEmpty {
                buffer.append(chunk)
                continue
            }
            if packet.complete {
                throw UltimateFTPClient.FTPError.connection(
                    "Control connection closed")
            }
        }
    }

    private func openConnection(port: UInt16) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw UltimateFTPClient.FTPError.connection("Invalid port")
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = ContinuationGate()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard gate.claim() else { return }
                connection.cancel()
                continuation.resume(throwing:
                    UltimateFTPClient.FTPError.connection("Timed out"))
            }
        }
        return connection
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func finishSending(on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
        }
    }

    private func receiveChunk(
        from connection: NWConnection
    ) async throws -> (data: Data?, complete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 64 * 1024
            ) { data, _, complete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: (data, complete))
                } else if complete {
                    continuation.resume(returning: (nil, true))
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (nil, false))
                }
            }
        }
    }

    private func receiveAll(from connection: NWConnection) async throws -> Data {
        var result = Data()
        while true {
            let packet = try await receiveChunk(from: connection)
            if let chunk = packet.data { result.append(chunk) }
            if packet.complete { break }
        }
        return result
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

actor UltimateFileSystemProvider: FileSystemProvider {
    let endpoint: FileEndpoint
    private let client: UltimateFTPClient

    init(device: UltimateDevice) {
        endpoint = .ultimate(device.id)
        client = UltimateFTPClient(device: device)
    }

    func list(_ path: ManagedPath) async throws -> [FilesystemItem] {
        try await client.list(path)
    }
    func item(_ path: ManagedPath) async throws -> FilesystemItem? {
        try await client.stat(path)
    }
    func makeDirectory(_ path: ManagedPath) async throws {
        try await client.makeDirectory(path)
    }
    func rename(_ source: ManagedPath, to destination: ManagedPath) async throws {
        try await client.rename(source, to: destination)
    }
    func delete(_ path: ManagedPath, recursive: Bool) async throws {
        if let item = try await client.stat(path), item.isDirectory {
            if recursive {
                for child in try await client.list(path) {
                    try await delete(child.path, recursive: true)
                }
            }
            try await client.deleteDirectory(path)
        } else {
            try await client.deleteFile(path)
        }
    }
    func download(_ source: ManagedPath, to localURL: URL,
                  progress: @escaping FileProgressHandler) async throws {
        try await client.download(source, to: localURL, progress: progress)
    }
    func upload(_ localURL: URL, to destination: ManagedPath,
                progress: @escaping FileProgressHandler) async throws {
        try await client.upload(localURL, to: destination, progress: progress)
    }
}
