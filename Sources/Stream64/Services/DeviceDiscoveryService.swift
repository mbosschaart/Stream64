import Foundation
import Combine

/// Bounded, cancellable LAN discovery for Ultimate-family REST endpoints.
@MainActor
final class DeviceDiscoveryService: ObservableObject {
    struct DiscoveredDevice: Identifiable, Equatable {
        let host: String
        let product: String?
        let firmwareVersion: String?
        let hostname: String?
        let uniqueID: String?

        var id: String {
            let normalizedID = uniqueID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalizedID?.isEmpty == false ? normalizedID! : host
        }

        var suggestedName: String {
            if let hostname, !hostname.isEmpty { return hostname }
            if let product, !product.isEmpty { return product }
            return "Commodore 64 Ultimate"
        }

        var detail: String {
            [product, firmwareVersion]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " · ")
        }
    }

    typealias HostProvider = @Sendable () -> [String]
    typealias Probe = @Sendable (String) async -> DiscoveredDevice?

    @Published private(set) var results: [DiscoveredDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedHostCount = 0
    @Published private(set) var totalHostCount = 0

    private let maximumConcurrentProbes: Int
    private let hostProvider: HostProvider
    private let probe: Probe
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?

    init(
        maximumConcurrentProbes: Int = 24,
        hostProvider: @escaping HostProvider = {
            LocalNetwork.discoveryHosts()
        },
        probe: @escaping Probe = { host in
            await DeviceDiscoveryService.probe(host: host)
        }
    ) {
        self.maximumConcurrentProbes = max(1, maximumConcurrentProbes)
        self.hostProvider = hostProvider
        self.probe = probe
    }

    deinit {
        scanTask?.cancel()
    }

    func start() {
        cancel()
        results = []
        scannedHostCount = 0

        let hosts = hostProvider()
        totalHostCount = hosts.count
        guard !hosts.isEmpty else {
            isScanning = false
            return
        }

        let scanID = UUID()
        activeScanID = scanID
        isScanning = true
        let limit = maximumConcurrentProbes
        let probe = probe

        scanTask = Task { [weak self] in
            await withTaskGroup(of: DiscoveredDevice?.self) { group in
                var iterator = hosts.makeIterator()
                for _ in 0..<min(limit, hosts.count) {
                    guard let host = iterator.next() else { break }
                    group.addTask { await probe(host) }
                }

                while let result = await group.next() {
                    guard let self, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    guard self.activeScanID == scanID else {
                        group.cancelAll()
                        return
                    }

                    self.scannedHostCount += 1
                    if let result {
                        self.merge(result)
                    }

                    if let host = iterator.next() {
                        group.addTask { await probe(host) }
                    }
                }
            }

            guard let self, self.activeScanID == scanID else { return }
            self.isScanning = false
            self.scanTask = nil
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        activeScanID = nil
        isScanning = false
    }

    func suggestedDevice(
        for result: DiscoveredDevice,
        avoiding existing: [UltimateDevice]
    ) -> UltimateDevice {
        var device = UltimateDevice.makeDefault(avoiding: existing)
        device.name = result.suggestedName
        device.host = result.host
        device.ultimateUniqueID = result.uniqueID
        return device
    }

    private func merge(_ result: DiscoveredDevice) {
        if let index = results.firstIndex(where: { $0.id == result.id }) {
            results[index] = result
        } else {
            results.append(result)
            results.sort { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
        }
    }

    nonisolated private static func probe(
        host: String
    ) async -> DiscoveredDevice? {
        let candidate = UltimateDevice(
            name: "Discovered Ultimate", host: host)
        do {
            let info = try await UltimateAPIClient(
                device: candidate, timeout: 0.45
            ).fetchInfo()
            return discoveryResult(host: host, info: info)
        } catch {
            return nil
        }
    }

    /// Rejects arbitrary JSON objects that happen to decode because every
    /// `/v1/info` field is optional. A product or stable hardware ID is needed
    /// before a host is presented as an Ultimate.
    nonisolated static func discoveryResult(
        host: String,
        info: UltimateAPIClient.DeviceInfo
    ) -> DiscoveredDevice? {
        func cleaned(_ value: String?) -> String? {
            let result = value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return result?.isEmpty == false ? result : nil
        }

        let product = cleaned(info.product)
        let uniqueID = cleaned(info.uniqueId)
        guard product != nil || uniqueID != nil else { return nil }
        return DiscoveredDevice(
            host: host,
            product: product,
            firmwareVersion: cleaned(info.firmwareVersion),
            hostname: cleaned(info.hostname),
            uniqueID: uniqueID
        )
    }
}
