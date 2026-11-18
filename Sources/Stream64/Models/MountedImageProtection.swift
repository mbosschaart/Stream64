import Foundation

enum MountedImageProtection {
    static func validateMutation(_ path: ManagedPath, drives: [UltimateAPIClient.DriveInfo]) throws {
        for drive in drives {
            var paths = drive.mountedImagePath.map { [$0] } ?? []
            paths += drive.partitions.map(\.path).filter { ["d64", "d71", "d81", "dnp", "g64", "g71"].contains(($0 as NSString).pathExtension.lowercased()) }
            for mounted in paths {
                let image = ManagedPath(mounted).rawValue.lowercased()
                let target = path.rawValue.lowercased()
                if target == image || target.hasPrefix(image + "/") || image.hasPrefix(target + "/") {
                    throw FileSystemError.unsupported("Changing \(path.name) while \(mounted) is mounted. Unmount it in Drive Bay first")
                }
            }
            // Older firmware may omit image_path. Recognise the filename at
            // any path component rather than silently allowing writes into it.
            if drive.mountedImagePath == nil, let name = drive.imageFile,
               path.rawValue.split(separator: "/").contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                throw FileSystemError.unsupported("Changing a mounted disk image. Unmount it in Drive Bay first")
            }
        }
    }
}
