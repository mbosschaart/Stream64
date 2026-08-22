import SwiftUI
import Combine

/// A serializable C64 color. Keeping this independent from SwiftUI's `Color`
/// makes palette documents stable and lets the renderer/recorder share it.
struct C64RGBAColor: Codable, Equatable, Identifiable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8 = 255

    var id: String { "\(red)-\(green)-\(blue)-\(alpha)" }

    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255,
              blue: Double(blue) / 255, opacity: Double(alpha) / 255)
    }

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
        red = UInt8((nsColor.redComponent * 255).rounded())
        green = UInt8((nsColor.greenComponent * 255).rounded())
        blue = UInt8((nsColor.blueComponent * 255).rounded())
        alpha = UInt8((nsColor.alphaComponent * 255).rounded())
    }

    var metalColor: SIMD4<UInt8> { .init(red, green, blue, alpha) }
}

struct CustomC64Palette: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var colors: [C64RGBAColor]

    init(id: UUID = UUID(), name: String, colors: [C64RGBAColor] = C64Palette.peptoPALColors) {
        self.id = id
        self.name = name
        self.colors = Array(colors.prefix(16))
        if self.colors.count < 16 {
            self.colors += Array(C64Palette.peptoPALColors.dropFirst(self.colors.count))
        }
    }
}

/// Shared named palette collection. Selections remain per-device, while edits
/// are immediately available to every stream.
@MainActor
final class PaletteLibrary: ObservableObject {
    static let shared = PaletteLibrary()
    private static let storageKey = "c64PaletteLibrary.v1"

    @Published private(set) var palettes: [CustomC64Palette] = [] {
        didSet { save() }
    }

    private init(defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([CustomC64Palette].self, from: data) else {
            return
        }
        palettes = decoded.map { CustomC64Palette(id: $0.id, name: $0.name, colors: $0.colors) }
    }

    func palette(id: UUID?) -> CustomC64Palette? {
        guard let id else { return nil }
        return palettes.first { $0.id == id }
    }

    func colors(for id: UUID?) -> [SIMD4<UInt8>]? {
        palette(id: id)?.colors.map(\.metalColor)
    }

    func add(name: String = "Custom Palette") {
        var candidate = name
        var suffix = 2
        while palettes.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        palettes.append(CustomC64Palette(name: candidate))
    }

    func update(_ palette: CustomC64Palette) {
        guard let index = palettes.firstIndex(where: { $0.id == palette.id }) else { return }
        palettes[index] = CustomC64Palette(id: palette.id, name: palette.name, colors: palette.colors)
    }

    func remove(id: UUID) {
        palettes.removeAll { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(palettes) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

extension DisplaySettings {
    /// Resolves a per-device selection against the shared library. A deleted
    /// custom palette deliberately falls back to Pepto PAL instead of leaving
    /// a stream without valid colors.
    var resolvedPalette: [SIMD4<UInt8>] {
        if palette == .custom, let custom = PaletteLibrary.shared.colors(for: selectedCustomPaletteID) {
            return custom
        }
        return C64Palette.palette(for: palette)
    }
}
