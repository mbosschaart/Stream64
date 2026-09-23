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

/// Selects whether movies contain the decoded Ultimate stream or the same
/// composited Metal image the viewer presents.
/// Network buffering: on by default over Wi-Fi (arrival jitter alone makes
/// the renderer drop frames), off by default on wired links (lowest input
/// latency). The user can force it either way.
enum NetworkBufferingMode: String, CaseIterable, Identifiable, Codable {
    case automatic = "Automatic"
    case on = "On"
    case off = "Off"

    var id: String { rawValue }

    static func automaticDefault(onWiFi: Bool) -> Bool { onWiFi }

    func isActive(onWiFi: Bool) -> Bool {
        switch self {
        case .automatic: Self.automaticDefault(onWiFi: onWiFi)
        case .on: true
        case .off: false
        }
    }

    /// The mode after the user flips buffering on the given link. Flipping
    /// back to that link's default returns to automatic, so a later Wi-Fi ↔
    /// Ethernet switch uses the new link's default again.
    func toggled(onWiFi: Bool) -> NetworkBufferingMode {
        let wanted = !isActive(onWiFi: onWiFi)
        if wanted == Self.automaticDefault(onWiFi: onWiFi) { return .automatic }
        return wanted ? .on : .off
    }
}

enum RecordingMode: String, CaseIterable, Identifiable, Codable {
    case source = "Source (fast)"
    case filtered = "Filtered viewer"

    var id: String { rawValue }
}

/// Geometry for filtered recordings. Source recordings always retain their
/// historical 384×272 PAL canvas for compatibility.
enum FilteredRecordingSize: String, CaseIterable, Identifiable, Codable {
    case fourThree = "Fixed 4:3 (768×576)"
    case matchViewer = "Match Viewer"

    var id: String { rawValue }
}

/// Codec trade-off for filtered exports. ProRes keeps 10-bit gradients but
/// produces much larger files than the compact H.264 option.
enum FilteredRecordingQuality: String, CaseIterable, Identifiable, Codable {
    case compactH264 = "Compact H.264"
    case proRes422HQ = "High Gradient Quality (ProRes 422 HQ)"

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
    case peptoPAL = "Pepto PAL (default)"
    case peptoNTSC = "Pepto NTSC"
    case colodore = "Colodore"
    case vice = "VICE"
    case deekay = "Deekay"
    case communityColors = "Community Colors"
    case ptoing = "Ptoing"
    case palVICII6569R1 = "PAL VIC-II 6569R1"
    case palVICII6569R3 = "PAL VIC-II 6569R3"
    case palVICII6569R4 = "PAL VIC-II 6569R4"
    case palVICII6569R5 = "PAL VIC-II 6569R5"
    case palVICII8565R2 = "PAL VIC-II 8565R2"
    case custom = "Custom"

    var id: String { rawValue }

    static var builtInCases: [PaletteChoice] {
        allCases.filter { $0 != .custom }
    }

    /// Source compatibility for the original single Pepto selection.
    static var pepto: PaletteChoice { .peptoPAL }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        // Display snapshots written before the palette library used this
        // label. Keep those per-device settings readable.
        self = PaletteChoice(rawValue: rawValue)
            ?? (rawValue == "Pepto (default)" ? .peptoPAL : .peptoPAL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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

/// Live CRT optics knobs (scanlines / bloom / phosphor mask / barrel).
/// Neutral `0.5` reproduces the previous hardcoded shader look.
final class CRTOpticsControls {
    var scanlineStrength: Float = 0.5
    var bloomAmount: Float = 0.5
    var maskIntensity: Float = 0.5
    var barrelDistortion: Float = 0.5
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
    /// 100 ms rides out the ~50–70 ms pauses macOS Wi-Fi takes about once a
    /// minute (seen in stream health logs); 60 ms underran on each one.
    @AppStorage("audioBufferMs") var audioBufferMs: Double = 100
    /// CoreAudio device UID, or empty for the system default output.
    @AppStorage("audioOutputDeviceUID") var audioOutputDeviceUID: String = ""

    // Network
    @AppStorage("connectTimeoutSeconds") var connectTimeoutSeconds: Double = 5
    @AppStorage("streamDurationSeconds") var streamDurationSeconds: Int = 0 // 0 = forever
    /// Wi-Fi gaps in stream health logs peaked around 250 ms, so 0.5 s has
    /// headroom without making input feel sluggish.
    @AppStorage("networkBufferSeconds") var networkBufferSeconds: Double = 0.5
    @AppStorage("networkBufferingMode")
    var networkBufferingMode: NetworkBufferingMode = .automatic
    /// Write one CSV row of stream health per second to ~/Library/Logs/Stream64.
    @AppStorage("streamHealthLogEnabled") var streamHealthLogEnabled: Bool = false

    func buffersStream(onWiFi: Bool) -> Bool {
        networkBufferingMode.isActive(onWiFi: onWiFi)
    }

    /// Video playout delay, or nil when buffering is off.
    func videoPlayoutDelaySeconds(onWiFi: Bool) -> Double? {
        buffersStream(onWiFi: onWiFi) ? networkBufferSeconds : nil
    }

    /// Audio jitter target. With buffering on it matches the video delay so
    /// sound stays in sync with the picture.
    func effectiveAudioBufferSeconds(onWiFi: Bool) -> Double {
        let jitter = audioBufferMs / 1000
        return buffersStream(onWiFi: onWiFi)
            ? max(jitter, networkBufferSeconds) : jitter
    }
    @AppStorage("recordingMode") var recordingMode: RecordingMode = .source
    @AppStorage("filteredRecordingSize")
    var filteredRecordingSize: FilteredRecordingSize = .fourThree
    @AppStorage("filteredRecordingQuality")
    var filteredRecordingQuality: FilteredRecordingQuality = .compactH264

    // General
    @AppStorage("reconnectAutomatically") var reconnectAutomatically: Bool = true
    @AppStorage("captureKeyboardWhenFocused") var captureKeyboardWhenFocused: Bool = true
    @AppStorage("confirmDestructiveActions") var confirmDestructiveActions: Bool = true
    @AppStorage("checkForUpdatesAutomatically") var checkForUpdatesAutomatically: Bool = true
    /// When on, open SID / Debug Trace / Memory Map windows retarget to the
    /// newly selected C64. Sound always follows selection regardless.
    @AppStorage("visualizationsAutoFollowSelected")
    var visualizationsAutoFollowSelected: Bool = true
    /// Metadata-based layouts; unknown playback retains all configured chips.
    @AppStorage("sidVisualizationAdaptation")
    var sidVisualizationAdaptation: SIDVisualizationAdaptation = .automatic
    @AppStorage("sidVisualizationC64Palette")
    var sidVisualizationC64Palette = false
    /// Keep the U64 debug stream alive for supported connected devices so
    /// Debug Trace / register SID windows never need to start it on demand.
    /// Off by default: the trace runs at roughly 32 Mbit/s, more than video
    /// and audio combined, which starves Wi-Fi links. Windows that need it
    /// lease it on open and it stops when the last one closes.
    @AppStorage("keepDebugStreamWarm")
    var keepDebugStreamWarm: Bool = false
    /// Emits U64 debug-stream lifecycle counters to macOS unified logging.
    /// Off by default; useful only when diagnosing device/trace issues.
    @AppStorage("debugLifecycleLogging")
    var debugLifecycleLogging: Bool = false
    /// Shows a real post-mix low-pass/kick trace above register-derived SID
    /// oscilloscope channels. Useful for filter and $D418 sample drums.
    @AppStorage("oscilloscopePostMixLowpassOverlay")
    var oscilloscopePostMixLowpassOverlay: Bool = false
    /// Used by SID Station when Songlengths.md5 has no duration for a selected subtune.
    @AppStorage("sidRadioFallbackDurationSeconds")
    var sidRadioFallbackDurationSeconds: Double = 180
    @AppStorage("sidRadioFadeOutEnabled")
    var sidRadioFadeOutEnabled: Bool = true
    @AppStorage("sidRadioQueueSize")
    var sidRadioQueueSize: Int = 5
    @AppStorage("sidRadioDiversity")
    var sidRadioDiversity: Double = 0.35
    @AppStorage("sidRadioPathCooldown")
    var sidRadioPathCooldown: Int = 8
}

// Allow enums in @AppStorage via RawRepresentable String conformance (already String-backed).
