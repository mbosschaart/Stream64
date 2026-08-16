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
        let searchPages: [String: SearchPageRecord]?
        let referenceData: ReferenceDataRecord?
    }

    private struct PreviewRecord: Codable {
        let preview: CSDBPreviewClient.Preview
        let fetchedAt: Date
    }

    private struct SearchPageRecord: Codable {
        let results: [Assembly64Client.SearchResult]
        let fetchedAt: Date
    }

    private struct ReferenceDataRecord: Codable {
        let categories: [Assembly64Client.Category]
        let presets: [Assembly64Client.AQLPreset]
        let fetchedAt: Date
    }

    private var records: [String: Record] = [:]
    private var previews: [String: PreviewRecord] = [:]
    private var searchPages: [String: SearchPageRecord] = [:]
    private var referenceData: ReferenceDataRecord?
    private let maximumRecords = 100

    private init() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        records = snapshot.records
        previews = snapshot.previews ?? [:]
        searchPages = snapshot.searchPages ?? [:]
        referenceData = snapshot.referenceData
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

    func searchResults(
        for key: String,
        maxAge: TimeInterval = 10 * 60
    ) -> [Assembly64Client.SearchResult]? {
        guard let record = searchPages[key],
              Date().timeIntervalSince(record.fetchedAt) <= maxAge else {
            searchPages.removeValue(forKey: key)
            return nil
        }
        return record.results
    }

    func storeSearchResults(
        _ results: [Assembly64Client.SearchResult],
        for key: String
    ) {
        searchPages[key] = SearchPageRecord(results: results, fetchedAt: Date())
        trim(&searchPages, maximum: 40) { $0.fetchedAt }
        save()
    }

    func referenceData(
        maxAge: TimeInterval = 24 * 60 * 60
    ) -> (
        categories: [Assembly64Client.Category],
        presets: [Assembly64Client.AQLPreset]
    )? {
        guard let referenceData,
              Date().timeIntervalSince(referenceData.fetchedAt) <= maxAge
        else {
            self.referenceData = nil
            return nil
        }
        return (referenceData.categories, referenceData.presets)
    }

    func storeReferenceData(
        categories: [Assembly64Client.Category],
        presets: [Assembly64Client.AQLPreset]
    ) {
        referenceData = ReferenceDataRecord(
            categories: categories,
            presets: presets,
            fetchedAt: Date())
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
            records: records,
            previews: previews,
            searchPages: searchPages,
            referenceData: referenceData)) else {
            return
        }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    private func trim<Value>(
        _ values: inout [String: Value],
        maximum: Int,
        date: (Value) -> Date
    ) {
        guard values.count > maximum else { return }
        for key in values.sorted(by: {
            date($0.value) < date($1.value)
        }).prefix(values.count - maximum).map(\.key) {
            values.removeValue(forKey: key)
        }
    }
}
