import XCTest
import CryptoKit
import ZIPFoundation
import MetalKit
import AVFoundation
@testable import Stream64

final class StaticUpdateTransport: UpdateHTTPTransport, @unchecked Sendable {
    let data: Data
    let statusCode: Int

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil)!
        )
    }
}


actor RecordingHTTPTransport: HTTPTransport {
    private var request: URLRequest?

    func recordedRequest() -> URLRequest? {
        return request
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(#"{"errors":[]}"#.utf8), response)
    }
}

actor ScriptedInputTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []

    var allInputEvents: [C64MachineInputEvent] {
        requests.compactMap(\.httpBody).flatMap {
            (try? JSONDecoder().decode(
                C64MachineInputEnvelope.self, from: $0).events) ?? []
        }
    }

    var inputEventCount: Int { allInputEvents.count }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let data: Data
        if path == "/v1/configs/Network Settings" {
            data = Data("""
            {"Network Settings":{
              "Ultimate DMA Service":"Disabled",
              "Web Remote Control Service":"Enabled"
            },"errors":[]}
            """.utf8)
        } else if path == "/v1/machine:readmem" {
            data = Data([0])
        } else {
            data = Data(#"{"errors":[]}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

actor FailingPressInputTransport: HTTPTransport {
    private(set) var sawReleaseAll = false

    func hasReleaseAll() -> Bool { sawReleaseAll }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let body = request.httpBody ?? Data()
        let events = (try? JSONDecoder().decode(
            C64MachineInputEnvelope.self,
            from: body).events) ?? []
        if events.contains(where: {
            $0.kind == .keyboard && $0.transition == .press
        }) {
            throw UltimateAPIClient.APIError.httpError(503, "temporary failure")
        }
        if events.contains(where: { $0.kind == .releaseAll }) {
            sawReleaseAll = true
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(#"{"errors":[]}"#.utf8), response)
    }
}

actor DelayedInputTransport: HTTPTransport {
    private var delayedRequest: CheckedContinuation<Void, Never>?
    private(set) var sawReleaseAll = false

    func hasReleaseAll() -> Bool { sawReleaseAll }

    func releaseDelayedRequest() {
        delayedRequest?.resume()
        delayedRequest = nil
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let body = request.httpBody ?? Data()
        let events = (try? JSONDecoder().decode(
            C64MachineInputEnvelope.self,
            from: body).events) ?? []
        if events.contains(where: {
            $0.kind == .keyboard && $0.transition == .press
        }) {
            await withCheckedContinuation { continuation in
                delayedRequest = continuation
            }
        }
        if events.contains(where: { $0.kind == .releaseAll }) {
            sawReleaseAll = true
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(#"{"errors":[]}"#.utf8), response)
    }
}

actor DebugRegisterHTTPTransport: HTTPTransport {
    private(set) var lastRequest: URLRequest?

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(#"{"value":"0x2C","errors":[]}"#.utf8), response)
    }
}

actor MenuScreenHTTPTransport: HTTPTransport {
    private(set) var lastRequest: URLRequest?

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        lastRequest = request
        var bytes = Data(repeating: 0, count: 2000)
        bytes[0] = 1
        bytes[1000] = 0x16
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (bytes, response)
    }
}
func makeArchive(
    _ entries: [(String, Data, Entry.EntryType, CompressionMethod)]
) throws -> Data {
    let archive = try Archive(
        data: Data(), accessMode: .create, pathEncoding: nil)
    for (path, data, type, compression) in entries {
        try archive.addEntry(
            with: path,
            type: type,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
    }
    return try XCTUnwrap(archive.data)
}



func makeSearchResult(
    id: String, category: Int, name: String
) throws -> Assembly64Client.SearchResult {
    let object: [String: Any] = [
        "id": id,
        "category": category,
        "name": name,
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(
        Assembly64Client.SearchResult.self, from: data)
}

