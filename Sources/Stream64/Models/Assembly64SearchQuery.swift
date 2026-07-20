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
