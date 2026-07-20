import Foundation

/// Regenerable Assembly64 metadata cache. User intent belongs in
/// `Assembly64LibraryStore`; API-derived data belongs under Caches and may be
/// discarded by the OS or after corruption without losing favorites/history.
actor Assembly64Cache {
    static let shared = Assembly64Cache()

    private struct Record: Codable {
        let metadata: Assembly64Client.Metadata
        let fetchedAt: Date
    }

    private struct Snapshot: Codable {
        let records: [String: Record]
        let previews: [String: PreviewRecord]?
    }

    private struct PreviewRecord: Codable {
        let preview: CSDBPreviewClient.Preview
        let fetchedAt: Date
    }

    private var records: [String: Record] = [:]
    private var previews: [String: PreviewRecord] = [:]
    private let maximumRecords = 100

    private init() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        records = snapshot.records
        previews = snapshot.previews ?? [:]
    }

    func metadata(for key: String,
                  maxAge: TimeInterval = 24 * 60 * 60) -> Assembly64Client.Metadata? {
        guard let record = records[key],
              Date().timeIntervalSince(record.fetchedAt) <= maxAge else {
            records.removeValue(forKey: key)
            return nil
        }
        return record.metadata
    }

    func store(_ metadata: Assembly64Client.Metadata, for key: String) {
        records[key] = Record(metadata: metadata, fetchedAt: Date())
        if records.count > maximumRecords {
            let oldestKeys = records.sorted {
                $0.value.fetchedAt < $1.value.fetchedAt
            }
            .prefix(records.count - maximumRecords)
            .map(\.key)
            for key in oldestKeys {
                records.removeValue(forKey: key)
            }
        }
        save()
    }

    func preview(for key: String,
                 maxAge: TimeInterval = 7 * 24 * 60 * 60) -> CSDBPreviewClient.Preview? {
        guard let record = previews[key],
              Date().timeIntervalSince(record.fetchedAt) <= maxAge else {
            previews.removeValue(forKey: key)
            return nil
        }
        return record.preview
    }

    func store(_ preview: CSDBPreviewClient.Preview, for key: String) {
        previews[key] = PreviewRecord(preview: preview, fetchedAt: Date())
        if previews.count > maximumRecords {
            let oldestKeys = previews.sorted {
                $0.value.fetchedAt < $1.value.fetchedAt
            }
            .prefix(previews.count - maximumRecords)
            .map(\.key)
            for key in oldestKeys {
                previews.removeValue(forKey: key)
            }
        }
        save()
    }

    private static var storeURL: URL {
        let root = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("Stream64", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("assembly64-metadata.json")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Snapshot(
            records: records, previews: previews)) else {
            return
        }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
