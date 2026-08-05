import SwiftUI
import Combine

enum ScalingMode: String, CaseIterable, Identifiable, Codable {
    case integer = "Integer"
    case aspectFit = "Fit (keep aspect)"
    case fill = "Fill"

    var id: String { rawValue }
}

enum FilterMode: String, CaseIterable, Identifiable, Codable {
    case sharp = "Sharp (nearest)"
    case smooth = "Smooth (linear)"
    case crt = "CRT (scanlines)"
    case crtTube = "CRT Tube (curved)"

    var id: String { rawValue }
}

enum TubeInput: String, CaseIterable, Identifiable, Codable {
    case svideo = "S-Video"
    case composite = "Composite"
    case rf = "RF (antenna)"

    var id: String { rawValue }

    /// Signal-degradation level passed to the shader.
    var signalLevel: Float {
        switch self {
        case .svideo: return 0
        case .composite: return 1
        case .rf: return 2
        }
    }
}

/// CRT phosphor/display color. This is intentionally separate from the C64
/// palette: it emulates the physical tube after the color picture has been
/// decoded, and only affects CRT rendering pipelines.
enum CRTScreenColor: String, CaseIterable, Identifiable, Codable {
    case color = "Color"
    case amber = "Amber"
    case green = "Green"
    case blackAndWhite = "Black & White"

    var id: String { rawValue }

    var shaderValue: Float {
        switch self {
        case .color: return 0
        case .amber: return 1
        case .green: return 2
        case .blackAndWhite: return 3
        }
    }
}

enum BezelChoice: String, CaseIterable, Identifiable, Codable {
    case c1702 = "Commodore 1702"
    case c1084 = "Commodore 1084S"

    var id: String { rawValue }

    /// Published phosphor/shadow-mask dot pitch for the physical monitor.
    var dotPitchMillimeters: Float {
        switch self {
        case .c1702: return 0.64
        case .c1084: return 0.42
        }
    }
}

enum PaletteChoice: String, CaseIterable, Identifiable, Codable {
    case pepto = "Pepto (default)"
    case colodore = "Colodore"
    case vice = "VICE"

    var id: String { rawValue }
}

/// Live picture-control values, read by the renderer every frame. A plain
/// class outside SwiftUI observation: knob drags write here directly so
/// adjustments apply at full frame rate without re-rendering the view tree
/// (each @AppStorage write publishes AppSettings and re-renders the whole
/// window — far too slow for a 60 Hz drag).
final class PictureControls {
    var brightness: Float = 0.5
    var contrast: Float = 0.5
    var saturation: Float = 0.5
    var tint: Float = 0.5
}

/// User preferences, backed by UserDefaults via @AppStorage.
@MainActor
final class AppSettings: ObservableObject {
    // Rendering/display settings are per device — see DisplaySettings.
    // (The legacy global keys remain in UserDefaults; DisplaySettings seeds
    // from them the first time it sees each device.)

    // Audio
    @AppStorage("audioEnabled") var audioEnabled: Bool = true
    @AppStorage("volume") var volume: Double = 0.8
    @AppStorage("audioBufferMs") var audioBufferMs: Double = 60

    // Network
    @AppStorage("connectTimeoutSeconds") var connectTimeoutSeconds: Double = 5
    @AppStorage("streamDurationSeconds") var streamDurationSeconds: Int = 0 // 0 = forever

    // General
    @AppStorage("reconnectAutomatically") var reconnectAutomatically: Bool = true
    @AppStorage("captureKeyboardWhenFocused") var captureKeyboardWhenFocused: Bool = true
    @AppStorage("confirmDestructiveActions") var confirmDestructiveActions: Bool = true
    @AppStorage("checkForUpdatesAutomatically") var checkForUpdatesAutomatically: Bool = true
}

// Allow enums in @AppStorage via RawRepresentable String conformance (already String-backed).
