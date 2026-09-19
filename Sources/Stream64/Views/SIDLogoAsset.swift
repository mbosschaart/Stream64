import AppKit
import MetalKit

/// Shared bundled artwork for KAOS and Signal Collage. Decode/upload once,
/// including across Club Mode cuts; packaged builds never access Bundle.module.
enum SIDLogoAsset {
    enum Kind: String, CaseIterable {
        case c64Ultimate, ultimate64

        init(product: String?) {
            let normalized = (product ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
            // C64 Ultimate and Ultimate 64 are different product families.
            if normalized.contains("c64ultimate") || normalized == "c64u" {
                self = .c64Ultimate
            } else if normalized.contains("ultimate64") || normalized.hasPrefix("u64") {
                self = .ultimate64
            } else {
                self = .c64Ultimate // Preserve existing artwork until identity is known.
            }
        }

        var resource: (name: String, extension: String) {
            switch self {
            case .c64Ultimate: return ("c64cu-logo", "webp")
            case .ultimate64: return ("u64_logo_badgeman", "jpg")
            }
        }
    }

    private static let images: [Kind: NSImage] = {
        var result: [Kind: NSImage] = [:]
        for kind in Kind.allCases {
            let resource = kind.resource
            let url = Bundle.main.url(forResource: resource.name, withExtension: resource.extension)
                ?? (ResourceBundle.isPackagedApp ? nil : Bundle.module.url(forResource: resource.name, withExtension: resource.extension))
            if let url, let image = NSImage(contentsOf: url) { result[kind] = image }
        }
        return result
    }()

    static func image(for kind: Kind) -> NSImage? { images[kind] }

    private static let lock = NSLock()
    private static var textures: [UInt64: [Kind: MTLTexture]] = [:]

    static func texture(device: MTLDevice, kind: Kind = .c64Ultimate) throws -> MTLTexture {
        lock.lock()
        defer { lock.unlock() }
        if let existing = textures[device.registryID]?[kind] { return existing }
        guard let cgImage = image(for: kind)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "SIDLogoAsset", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundled SID logo could not be decoded."])
        }
        let texture = try MTKTextureLoader(device: device).newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft.rawValue,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ])
        textures[device.registryID, default: [:]][kind] = texture
        return texture
    }
}
