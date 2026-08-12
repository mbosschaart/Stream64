import SwiftUI
import Combine

/// Per-device rendering/display settings, persisted per device ID. Global
/// AppSettings keeps audio hardware, network, and general preferences;
/// everything about how a stream *looks* lives here so two devices can
/// render differently (e.g. one RF, one S-Video).
@MainActor
final class DisplaySettings: ObservableObject {
    let deviceID: UUID

    /// One instance per device, shared by the session (renderer) and the
    /// Preferences window so edits in either place affect the same object.
    private static var instances: [UUID: DisplaySettings] = [:]
    static func shared(for deviceID: UUID) -> DisplaySettings {
        if let existing = instances[deviceID] { return existing }
        let created = DisplaySettings(deviceID: deviceID)
        instances[deviceID] = created
        return created
    }

    @Published var scalingMode: ScalingMode { didSet { save() } }
    @Published var filterMode: FilterMode { didSet { save() } }
    @Published var palette: PaletteChoice { didSet { save() } }
    @Published var tubeInput: TubeInput { didSet { save() } }
    @Published var crtScreenColor: CRTScreenColor { didSet { save() } }
    @Published var crtDirtyGlass: Bool { didSet { save() } }
    @Published var showFPS: Bool { didSet { save() } }
    /// CRT Tube phosphor / shadow-mask geometry (1702 vs 1084S pitch).
    /// Physical monitor-case chrome was removed; this only feeds shaders.
    @Published var bezelStyle: BezelChoice { didSet { save() } }
    @Published var bezelReflection: Bool { didSet { save() } }
    // Monitor picture controls (1702 front panel), 0...1, neutral 0.5.
    @Published var monBrightness: Double { didSet { picture.brightness = Float(monBrightness); save() } }
    @Published var monContrast: Double { didSet { picture.contrast = Float(monContrast); save() } }
    @Published var monColor: Double { didSet { picture.saturation = Float(monColor); save() } }
    @Published var monTint: Double { didSet { picture.tint = Float(monTint); save() } }
    // CRT optics knobs, 0...1, neutral 0.5 (= previous hardcoded look).
    @Published var crtScanlineStrength: Double {
        didSet { optics.scanlineStrength = Float(crtScanlineStrength); save() }
    }
    @Published var crtBloomAmount: Double {
        didSet { optics.bloomAmount = Float(crtBloomAmount); save() }
    }
    @Published var crtMaskIntensity: Double {
        didSet { optics.maskIntensity = Float(crtMaskIntensity); save() }
    }
    @Published var crtBarrelDistortion: Double {
        didSet { optics.barrelDistortion = Float(crtBarrelDistortion); save() }
    }

    /// Live conduit to the renderer (read every frame, bypasses SwiftUI).
    let picture = PictureControls()
    let optics = CRTOpticsControls()

    private struct Snapshot: Codable {
        var scalingMode: ScalingMode
        var filterMode: FilterMode
        var palette: PaletteChoice
        var tubeInput: TubeInput
        /// Optional for backward compatibility with existing per-device JSON.
        var crtScreenColor: CRTScreenColor?
        var crtDirtyGlass: Bool?
        var showFPS: Bool
        /// Ignored; kept optional so older per-device JSON still decodes.
        var showBezel: Bool?
        var bezelStyle: BezelChoice
        var bezelReflection: Bool
        var monBrightness: Double
        var monContrast: Double
        var monColor: Double
        var monTint: Double
        var crtScanlineStrength: Double?
        var crtBloomAmount: Double?
        var crtMaskIntensity: Double?
        var crtBarrelDistortion: Double?
    }

    private var storageKey: String { "displaySettings.\(deviceID.uuidString)" }
    private var loaded = false

    init(deviceID: UUID) {
        self.deviceID = deviceID

        let defaults = UserDefaults.standard
        if let raw = defaults.data(forKey: "displaySettings.\(deviceID.uuidString)"),
           let data = try? JSONDecoder().decode(Snapshot.self, from: raw) {
            scalingMode = data.scalingMode
            filterMode = data.filterMode
            palette = data.palette
            tubeInput = data.tubeInput
            crtScreenColor = data.crtScreenColor ?? .color
            crtDirtyGlass = data.crtDirtyGlass ?? false
            showFPS = data.showFPS
            bezelStyle = data.bezelStyle
            bezelReflection = data.bezelReflection
            monBrightness = data.monBrightness
            monContrast = data.monContrast
            monColor = data.monColor
            monTint = data.monTint
            crtScanlineStrength = data.crtScanlineStrength ?? 0.5
            crtBloomAmount = data.crtBloomAmount ?? 0.5
            crtMaskIntensity = data.crtMaskIntensity ?? 0.5
            crtBarrelDistortion = data.crtBarrelDistortion ?? 0.5
        } else {
            // First run for this device: seed from the legacy global keys so
            // existing users keep the look they had before settings became
            // per-device.
            scalingMode = ScalingMode(rawValue: defaults.string(forKey: "scalingMode") ?? "") ?? .aspectFit
            filterMode = FilterMode(rawValue: defaults.string(forKey: "filterMode") ?? "") ?? .sharp
            palette = PaletteChoice(rawValue: defaults.string(forKey: "palette") ?? "") ?? .pepto
            tubeInput = TubeInput(rawValue: defaults.string(forKey: "tubeInput") ?? "") ?? .svideo
            crtScreenColor = CRTScreenColor(
                rawValue: defaults.string(forKey: "crtScreenColor") ?? "") ?? .color
            crtDirtyGlass = defaults.object(
                forKey: "crtDirtyGlass") as? Bool ?? false
            showFPS = defaults.bool(forKey: "showFPS")
            bezelStyle = BezelChoice(rawValue: defaults.string(forKey: "bezelStyle") ?? "") ?? .c1702
            bezelReflection = defaults.object(forKey: "bezelReflection") as? Bool ?? true
            monBrightness = defaults.object(forKey: "monBrightness") as? Double ?? 0.5
            monContrast = defaults.object(forKey: "monContrast") as? Double ?? 0.5
            monColor = defaults.object(forKey: "monColor") as? Double ?? 0.5
            monTint = defaults.object(forKey: "monTint") as? Double ?? 0.5
            crtScanlineStrength = 0.5
            crtBloomAmount = 0.5
            crtMaskIntensity = 0.5
            crtBarrelDistortion = 0.5
        }

        picture.brightness = Float(monBrightness)
        picture.contrast = Float(monContrast)
        picture.saturation = Float(monColor)
        picture.tint = Float(monTint)
        optics.scanlineStrength = Float(crtScanlineStrength)
        optics.bloomAmount = Float(crtBloomAmount)
        optics.maskIntensity = Float(crtMaskIntensity)
        optics.barrelDistortion = Float(crtBarrelDistortion)
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        let data = Snapshot(
            scalingMode: scalingMode, filterMode: filterMode,
            palette: palette, tubeInput: tubeInput,
            crtScreenColor: crtScreenColor,
            crtDirtyGlass: crtDirtyGlass,
            showFPS: showFPS, showBezel: nil,
            bezelStyle: bezelStyle, bezelReflection: bezelReflection,
            monBrightness: monBrightness, monContrast: monContrast,
            monColor: monColor, monTint: monTint,
            crtScanlineStrength: crtScanlineStrength,
            crtBloomAmount: crtBloomAmount,
            crtMaskIntensity: crtMaskIntensity,
            crtBarrelDistortion: crtBarrelDistortion)
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: storageKey)
        }
    }
}
