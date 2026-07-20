import Foundation
import Combine

/// User-facing search facets supported by Assembly64's AQL presets.
/// Empty strings / nil values mean "all".
struct Assembly64SearchFilters: Codable, Equatable, Hashable {
    var repository = ""
    var fileType = ""
    var year: Int?
    var minimumRating: Int?
    var latest = ""
    var sort = "name"
    var order = "asc"

    var hasActiveFilters: Bool {
        !repository.isEmpty || !fileType.isEmpty || year != nil
            || minimumRating != nil || !latest.isEmpty
            || sort != "name" || order != "asc"
    }
}

/// Persistent, local library state for Assembly64. The public service remains
/// the source of truth for search/files; this store only owns user intent
/// (favorites, history, saved searches, remembered actions) and a short-lived
/// metadata cache so reopening an item does not repeatedly hit the API.
@MainActor
final class Assembly64LibraryStore: ObservableObject {
    struct Favorite: Codable, Identifiable, Hashable {
        let result: Assembly64Client.SearchResult
        let addedAt: Date

        var id: String { result.libraryKey }
    }

    struct RecentItem: Codable, Identifiable, Hashable {
        let result: Assembly64Client.SearchResult
        let openedAt: Date

        var id: String { result.libraryKey }
    }

    struct SavedSearch: Codable, Identifiable, Hashable {
        let id: UUID
        var name: String
        var text: String
        var categoryID: Int?
        var filters: Assembly64SearchFilters
        let createdAt: Date
    }

    private struct Snapshot: Codable {
        var favorites: [Favorite]
        var recents: [RecentItem]
        var savedSearches: [SavedSearch]
        var rememberedActions: [String: String]
    }

    @Published private(set) var favorites: [Favorite] = [] {
        didSet { save() }
    }
    @Published private(set) var recents: [RecentItem] = [] {
        didSet { save() }
    }
    @Published private(set) var savedSearches: [SavedSearch] = [] {
        didSet { save() }
    }
    @Published private(set) var rememberedActions: [String: String] = [:] {
        didSet { save() }
    }
    private var loaded = false
    private let storeURL: URL

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL
        load()
        loaded = true
    }

    var favoriteResults: [Assembly64Client.SearchResult] {
        favorites.map(\.result).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var recentResults: [Assembly64Client.SearchResult] {
        recents.map(\.result)
    }

    func isFavorite(_ result: Assembly64Client.SearchResult) -> Bool {
        favorites.contains { $0.id == result.libraryKey }
    }

    func toggleFavorite(_ result: Assembly64Client.SearchResult) {
        if let index = favorites.firstIndex(where: { $0.id == result.libraryKey }) {
            favorites.remove(at: index)
        } else {
            favorites.append(Favorite(result: result, addedAt: Date()))
        }
    }

    func recordOpened(_ result: Assembly64Client.SearchResult) {
        recents.removeAll { $0.id == result.libraryKey }
        recents.insert(RecentItem(result: result, openedAt: Date()), at: 0)
        if recents.count > 30 {
            recents.removeLast(recents.count - 30)
        }
    }

    func saveSearch(name: String, text: String, categoryID: Int?,
                    filters: Assembly64SearchFilters) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        if let index = savedSearches.firstIndex(where: {
            $0.text == text && $0.categoryID == categoryID && $0.filters == filters
        }) {
            savedSearches[index].name = normalizedName
        } else {
            savedSearches.append(SavedSearch(
                id: UUID(),
                name: normalizedName,
                text: text,
                categoryID: categoryID,
                filters: filters,
                createdAt: Date()))
        }
        savedSearches.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func removeSavedSearch(_ search: SavedSearch) {
        savedSearches.removeAll { $0.id == search.id }
    }

    static func entryActionKey(result: Assembly64Client.SearchResult,
                               entry: Assembly64Client.FileEntry) -> String {
        "\(result.libraryKey):\(entry.id)"
    }

    func rememberedAction(result: Assembly64Client.SearchResult,
                          entry: Assembly64Client.FileEntry) -> String? {
        rememberedActions[Self.entryActionKey(result: result, entry: entry)]
    }

    func rememberAction(_ action: String, result: Assembly64Client.SearchResult,
                        entry: Assembly64Client.FileEntry) {
        rememberedActions[Self.entryActionKey(result: result, entry: entry)] = action
    }

    private static var defaultStoreURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Stream64", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("assembly64-library.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        favorites = snapshot.favorites
        recents = snapshot.recents
        savedSearches = snapshot.savedSearches
        rememberedActions = snapshot.rememberedActions
    }

    private func save() {
        guard loaded else { return }
        let snapshot = Snapshot(
            favorites: favorites,
            recents: recents,
            savedSearches: savedSearches,
            rememberedActions: rememberedActions)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
