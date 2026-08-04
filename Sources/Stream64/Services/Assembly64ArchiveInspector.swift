import Foundation
import ZIPFoundation

/// Safe, read-only ZIP inspection for complete Assembly64 entry archives.
/// No archive path is ever written to disk: selected regular files are
/// extracted directly into bounded `Data` after the central directory passes
/// traversal, symlink, count, size and compression-ratio checks.
struct Assembly64ArchiveInspector {
    struct Limits: Equatable {
        var maximumArchiveBytes = 100 * 1024 * 1024
        var maximumEntryCount = 500
        var maximumSingleFileBytes: UInt64 = 64 * 1024 * 1024
        var maximumTotalUncompressedBytes: UInt64 = 512 * 1024 * 1024
        var maximumCompressionRatio: Double = 200

        static let `default` = Limits()
    }

    struct Item: Identifiable, Hashable {
        let archivePath: String
        let normalizedPath: String
        let compressedSize: UInt64
        let uncompressedSize: UInt64

        var id: String { normalizedPath }
        var filename: String { (normalizedPath as NSString).lastPathComponent }
        var fileExtension: String {
            (filename as NSString).pathExtension.lowercased()
        }
        var isSupportedByDevice: Bool {
            switch fileExtension {
            case "prg", "d64", "g64", "d71", "g71", "d81", "sid", "crt":
                return true
            default:
                return false
            }
        }
    }

    enum InspectionError: LocalizedError, Equatable {
        case archiveTooLarge(Int)
        case invalidArchive
        case tooManyEntries(Int)
        case unsafePath(String)
        case symbolicLink(String)
        case duplicatePath(String)
        case fileTooLarge(String)
        case totalSizeExceeded
        case suspiciousCompression(String)
        case missingEntry(String)
        case extractedSizeExceeded(String)

        var errorDescription: String? {
            switch self {
            case .archiveTooLarge(let bytes):
                return "Archive is too large to inspect safely (\(bytes) bytes)."
            case .invalidArchive:
                return "The downloaded file is not a readable ZIP archive."
            case .tooManyEntries(let count):
                return "Archive contains too many entries (\(count))."
            case .unsafePath(let path):
                return "Archive contains an unsafe path: \(path)"
            case .symbolicLink(let path):
                return "Archive contains a symbolic link: \(path)"
            case .duplicatePath(let path):
                return "Archive contains duplicate path: \(path)"
            case .fileTooLarge(let path):
                return "Archive member is too large: \(path)"
            case .totalSizeExceeded:
                return "Archive expands beyond the safe size limit."
            case .suspiciousCompression(let path):
                return "Archive member has a suspicious compression ratio: \(path)"
            case .missingEntry(let path):
                return "Archive member is no longer available: \(path)"
            case .extractedSizeExceeded(let path):
                return "Archive member exceeded its declared size: \(path)"
            }
        }
    }

    static func inspect(_ data: Data, limits: Limits = .default) throws -> [Item] {
        guard data.count <= limits.maximumArchiveBytes else {
            throw InspectionError.archiveTooLarge(data.count)
        }
        let archive: Archive
        do {
            archive = try Archive(
                data: data, accessMode: .read, pathEncoding: nil)
        } catch {
            throw InspectionError.invalidArchive
        }

        var items: [Item] = []
        var seenPaths: Set<String> = []
        var entryCount = 0
        var totalUncompressed: UInt64 = 0

        for entry in archive {
            entryCount += 1
            guard entryCount <= limits.maximumEntryCount else {
                throw InspectionError.tooManyEntries(entryCount)
            }

            let normalized = try normalizedPath(entry.path)
            guard seenPaths.insert(normalized.lowercased()).inserted else {
                throw InspectionError.duplicatePath(normalized)
            }

            if entry.type == .symlink {
                throw InspectionError.symbolicLink(normalized)
            }
            guard entry.uncompressedSize <= limits.maximumSingleFileBytes else {
                throw InspectionError.fileTooLarge(normalized)
            }
            let (newTotal, overflow) = totalUncompressed.addingReportingOverflow(
                entry.uncompressedSize)
            guard !overflow,
                  newTotal <= limits.maximumTotalUncompressedBytes else {
                throw InspectionError.totalSizeExceeded
            }
            totalUncompressed = newTotal

            if entry.uncompressedSize > 0 {
                guard entry.compressedSize > 0 else {
                    throw InspectionError.suspiciousCompression(normalized)
                }
                let ratio = Double(entry.uncompressedSize)
                    / Double(entry.compressedSize)
                guard ratio <= limits.maximumCompressionRatio else {
                    throw InspectionError.suspiciousCompression(normalized)
                }
            }

            guard entry.type == .file else { continue }
            items.append(Item(
                archivePath: entry.path,
                normalizedPath: normalized,
                compressedSize: entry.compressedSize,
                uncompressedSize: entry.uncompressedSize))
        }
        return items.sorted {
            $0.normalizedPath.localizedStandardCompare($1.normalizedPath)
                == .orderedAscending
        }
    }

    static func extract(_ item: Item, from data: Data,
                        limits: Limits = .default) throws -> Data {
        let inspected = try inspect(data, limits: limits)
        return try extract(
            item, from: data, inspected: inspected, limits: limits)
    }

    /// Extract using an inspection already performed for the same immutable
    /// archive bytes. ArchivePreview stores this index, so selecting several
    /// members does not repeatedly scan and validate the entire central
    /// directory.
    static func extract(
        _ item: Item,
        from data: Data,
        inspected: [Item],
        limits: Limits = .default
    ) throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(
                data: data, accessMode: .read, pathEncoding: nil)
        } catch {
            throw InspectionError.invalidArchive
        }
        guard inspected.contains(where: { $0.id == item.id }),
              let entry = archive.first(where: {
                  $0.type == .file && $0.path == item.archivePath
              }) else {
            throw InspectionError.missingEntry(item.normalizedPath)
        }

        guard entry.uncompressedSize <= UInt64(Int.max) else {
            throw InspectionError.fileTooLarge(item.normalizedPath)
        }
        var output = Data()
        output.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            guard output.count + chunk.count <= Int(entry.uncompressedSize),
                  output.count + chunk.count <= Int(limits.maximumSingleFileBytes) else {
                throw InspectionError.extractedSizeExceeded(item.normalizedPath)
            }
            output.append(chunk)
        }
        guard output.count == Int(entry.uncompressedSize) else {
            throw InspectionError.extractedSizeExceeded(item.normalizedPath)
        }
        return output
    }

    private static func normalizedPath(_ path: String) throws -> String {
        let slashes = path.replacingOccurrences(of: "\\", with: "/")
        guard !slashes.hasPrefix("/"),
              !(slashes as NSString).isAbsolutePath else {
            throw InspectionError.unsafePath(path)
        }
        let components = slashes.split(
            separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              !components.contains("."),
              !components.contains("..") else {
            throw InspectionError.unsafePath(path)
        }
        return components.joined(separator: "/")
    }
}
