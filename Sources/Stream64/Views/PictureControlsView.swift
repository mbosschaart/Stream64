import SwiftUI

/// Modal picture controls used when the physical monitor case—and therefore
/// its front-panel knobs—is not visible.
struct PictureControlsView: View {
    let display: DisplaySettings
    let onDone: () -> Void

    @State private var brightness: Double
    @State private var color: Double
    @State private var tint: Double
    @State private var contrast: Double
    @State private var scanlineStrength: Double
    @State private var bloomAmount: Double
    @State private var maskIntensity: Double
    @State private var barrelDistortion: Double

    init(
        display: DisplaySettings,
        onDone: @escaping () -> Void = {}
    ) {
        self.display = display
        self.onDone = onDone
        _brightness = State(initialValue: display.monBrightness)
        _color = State(initialValue: display.monColor)
        _tint = State(initialValue: display.monTint)
        _contrast = State(initialValue: display.monContrast)
        _scanlineStrength = State(initialValue: display.crtScanlineStrength)
        _bloomAmount = State(initialValue: display.crtBloomAmount)
        _maskIntensity = State(initialValue: display.crtMaskIntensity)
        _barrelDistortion = State(initialValue: display.crtBarrelDistortion)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    control("Brightness", value: $brightness)
                    control("Color", value: $color)
                    control("Tint", value: $tint)
                    control("Contrast", value: $contrast)
                } header: {
                    Text("Picture")
                } footer: {
                    Text(
                        "The center position is neutral. Higher brightness "
                            + "and color settings deliberately allow CRT "
                            + "overdrive."
                    )
                }

                Section {
                    control("Scanlines", value: $scanlineStrength)
                    control("Bloom", value: $bloomAmount)
                    control("Phosphor Mask", value: $maskIntensity)
                    control("Barrel Distortion", value: $barrelDistortion)
                } header: {
                    Text("CRT Optics")
                } footer: {
                    Text(
                        "Center is the previous hardcoded CRT look. Lower "
                            + "values soften the effect; the right half "
                            + "ramps up to about 4× that strength."
                    )
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Reset to Neutral") {
                    brightness = 0.5
                    color = 0.5
                    tint = 0.5
                    contrast = 0.5
                    scanlineStrength = 0.5
                    bloomAmount = 0.5
                    maskIntensity = 0.5
                    barrelDistortion = 0.5
                }
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 440, height: 620)
        .navigationTitle("Picture Controls")
        .onChange(of: brightness) {
            display.picture.brightness = Float(brightness)
        }
        .onChange(of: color) {
            display.picture.saturation = Float(color)
        }
        .onChange(of: tint) {
            display.picture.tint = Float(tint)
        }
        .onChange(of: contrast) {
            display.picture.contrast = Float(contrast)
        }
        .onChange(of: scanlineStrength) {
            display.optics.scanlineStrength = Float(scanlineStrength)
        }
        .onChange(of: bloomAmount) {
            display.optics.bloomAmount = Float(bloomAmount)
        }
        .onChange(of: maskIntensity) {
            display.optics.maskIntensity = Float(maskIntensity)
        }
        .onChange(of: barrelDistortion) {
            display.optics.barrelDistortion = Float(barrelDistortion)
        }
        .onDisappear {
            display.monBrightness = brightness
            display.monColor = color
            display.monTint = tint
            display.monContrast = contrast
            display.crtScanlineStrength = scanlineStrength
            display.crtBloomAmount = bloomAmount
            display.crtMaskIntensity = maskIntensity
            display.crtBarrelDistortion = barrelDistortion
        }
    }

    private func control(
        _ label: String,
        value: Binding<Double>
    ) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: value, in: 0...1)
                    .frame(width: 230)
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        } label: {
            Text(label)
        }
    }
}

/// Owns one movable non-modal controls panel per device. A sheet is
/// intentionally not used: sheets cannot move and dim/deactivate the viewer
/// whose picture the user is trying to adjust.
@MainActor
final class PictureControlsPanelController:
    NSWindowController, NSWindowDelegate {
    private static var panels: [
        UUID: PictureControlsPanelController
    ] = [:]

    private let deviceID: UUID

    static func show(display: DisplaySettings) {
        if let existing = panels[display.deviceID],
           let window = existing.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = PictureControlsPanelController(display: display)
        panels[display.deviceID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(display: DisplaySettings) {
        deviceID = display.deviceID
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Picture Controls"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()

        super.init(window: panel)
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: PictureControlsView(
                display: display,
                onDone: { [weak self] in self?.close() }
            )
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        Self.panels.removeValue(forKey: deviceID)
    }
}
