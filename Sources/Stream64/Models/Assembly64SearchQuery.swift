import Foundation

/// Deterministic AQL composition kept outside the view so quoting and filter
/// combinations can be tested without launching SwiftUI.
struct Assembly64SearchQuery: Equatable {
    var text: String
    var categoryName: String?
    var filters: Assembly64SearchFilters

    var hasConstraint: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || categoryName != nil || filters.hasActiveFilters
    }

    var aql: String {
        var terms: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let safe = trimmed.replacingOccurrences(of: "\"", with: "")
            let value = safe.contains(" ") ? "\"\(safe)\"" : safe
            terms.append("name:\(value)")
        }
        if let categoryName, !categoryName.isEmpty {
            terms.append("subcat:\(categoryName.lowercased())")
        }
        if !filters.repository.isEmpty {
            terms.append("repo:\(filters.repository)")
        }
        if !filters.fileType.isEmpty {
            terms.append("type:\(filters.fileType)")
        }
        if let year = filters.year {
            terms.append("date:\(year)")
        }
        if let rating = filters.minimumRating {
            terms.append("rating:>=\(rating)")
        }
        if !filters.latest.isEmpty {
            terms.append("latest:\(filters.latest)")
        }
        terms.append("sort:\(filters.sort)")
        terms.append("order:\(filters.order)")
        return terms.joined(separator: " ")
    }
}

/// Curated discovery lists built from the same dynamic categories and AQL
/// sorting that the normal Assembly64 search exposes—there is no separate
/// hard-coded “top 200” endpoint.
enum Assembly64DiscoveryList: String, CaseIterable, Identifiable, Codable {
    case demoTop200
    case games
    case graphics
    case music
    case onefileDemos
    case tools
    case recentReleases

    var id: String { rawValue }

    var title: String {
        switch self {
        case .demoTop200: return "Demo Top 200"
        case .games: return "Games Top 200"
        case .graphics: return "Graphics Top 200"
        case .music: return "Music Top 200"
        case .onefileDemos: return "OneFile Demos Top 200"
        case .tools: return "Tools Top 200"
        case .recentReleases: return "Recent Releases"
        }
    }

    var subtitle: String {
        switch self {
        case .demoTop200: return "Assembly64 native Demos chart"
        case .games: return "Assembly64 native Games chart"
        case .graphics: return "Assembly64 native Graphics chart"
        case .music: return "Assembly64 native Music chart"
        case .onefileDemos: return "Assembly64 native OneFile Demos chart"
        case .tools: return "Assembly64 native Tools chart"
        case .recentReleases: return "Recently updated Assembly64 releases"
        }
    }

    var chartType: String? {
        switch self {
        case .demoTop200: return "demos"
        case .games: return "games"
        case .graphics: return "graphics"
        case .music: return "music"
        case .onefileDemos: return "onefiledemos"
        case .tools: return "tools"
        case .recentReleases: return nil
        }
    }

    func query(
        categories: [Assembly64Client.Category],
        presets: [Assembly64Client.AQLPreset] = []
    ) -> Assembly64SearchQuery {
        var filters = Assembly64SearchFilters()
        switch self {
        case .recentReleases:
            filters.latest = presets.first(where: { $0.type == "latest" })?
                .values.first(where: { $0.aqlKey == "1month" })?.aqlKey
                ?? presets.first(where: { $0.type == "latest" })?
                    .values.first?.aqlKey
                ?? "1month"
            filters.sort = presets.first(where: { $0.type == "sort" })?
                .values.first(where: { $0.aqlKey == "updated" })?.aqlKey
                ?? "updated"
            filters.order = "desc"
        default:
            filters.sort = presets.first(where: { $0.type == "sort" })?
                .values.first(where: { $0.aqlKey == "rating" })?.aqlKey
                ?? "rating"
            filters.order = "desc"
        }

        let categoryHint: String?
        switch self {
        case .demoTop200, .onefileDemos:
            categoryHint = "demo"
        case .games:
            categoryHint = "game"
        case .music:
            categoryHint = "music"
        case .tools:
            categoryHint = "tool"
        case .graphics:
            categoryHint = "graphic"
        case .recentReleases:
            categoryHint = nil
        }
        let category = categoryHint.flatMap { hint in
            categories.first {
                ($0.name + " " + ($0.description ?? ""))
                    .localizedCaseInsensitiveContains(hint)
            }
        }
        return Assembly64SearchQuery(
            text: "",
            categoryName: category?.name,
            filters: filters)
    }
}
