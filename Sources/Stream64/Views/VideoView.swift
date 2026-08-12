import SwiftUI
import MetalKit

/// SwiftUI wrapper around the Metal-backed video view, with C64 keyboard capture.
struct VideoView: NSViewRepresentable {
    /// Plain reference — must not be `@ObservedObject`. Session publishes fps /
    /// presentFPS often enough that observing it would call `updateNSView`
    /// every tick and rebuild any SwiftUI parents that also observe session
    /// (collapsing open context menus).
    let session: DeviceSession
    /// Observed directly: updateNSView pushes these values to the renderer,
    /// so the view must re-render when they change — regardless of whether
    /// the host view (pane, grid tile) observes them.
    @ObservedObject var display: DisplaySettings
    @EnvironmentObject var settings: AppSettings
    let monitorCaseVisible: Bool

    init(session: DeviceSession, monitorCaseVisible: Bool = false) {
        self.session = session
        self.display = session.display
        self.monitorCaseVisible = monitorCaseVisible
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> KeyCapturingMTKView {
        let view = KeyCapturingMTKView(frame: .zero)
        let renderer = MetalFrameRenderer(mtkView: view)
        context.coordinator.renderer = renderer
        renderer?.onLoadStats = { [weak session = context.coordinator.session] presentFPS, gpuBehind in
            MainActor.assumeIsolated {
                session?.reportVideoRenderLoad(
                    presentFPS: presentFPS, gpuBehind: gpuBehind)
            }
        }
        view.onKeyDown = { input in
            MainActor.assumeIsolated {
                context.coordinator.session.handleHostKeyDown(input)
            }
        }
        view.onKeyUp = { input in
            MainActor.assumeIsolated {
                context.coordinator.session.handleHostKeyUp(input)
            }
        }
        view.onFlagsChanged = { keyCode, modifiers in
            MainActor.assumeIsolated {
                context.coordinator.session.handleModifierChange(
                    keyCode: keyCode, modifiers: modifiers)
            }
        }
        view.onFocusLost = {
            Task { @MainActor in
                context.coordinator.session.input.releaseAll()
            }
        }
        context.coordinator.session.videoReceiver.onFrame = {
            [weak renderer, weak session = context.coordinator.session] frame in
            let height = frame.count / VideoReceiver.width
            if VideoReceiver.isSupportedFrameHeight(height),
               let audio = session?.audioReceiver {
                // RF hum follows PAL 50 / NTSC 60 — only write on change.
                let hum = height <= VideoReceiver.ntscHeight ? 60.0 : 50.0
                if audio.mainsHumFrequencyHz != hum {
                    audio.mainsHumFrequencyHz = hum
                }
            }
            renderer?.submitFrame(frame)
        }
        context.coordinator.session.captureFrame = { [weak renderer] completion in
            guard let renderer else {
                completion(nil)
                return
            }
            renderer.requestFilteredScreenshot(completion: completion)
        }
        context.coordinator.session.beginPowerOffVisualEffect = {
            [weak renderer] in
            renderer?.beginPowerOffEffect()
        }
        context.coordinator.session.cancelPowerOffVisualEffect = {
            [weak renderer] in
            renderer?.cancelPowerOffEffect()
        }
        return view
    }

    func updateNSView(_ nsView: KeyCapturingMTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else {
            nsView.captureEnabled = settings.captureKeyboardWhenFocused
            return
        }
        let bezelSurfaceMode: Float = monitorCaseVisible
            ? (display.bezelStyle == .c1702 ? 1 : 2)
            : 0
        let signalLevel = display.tubeInput.signalLevel
        let dotPitch = display.bezelStyle.dotPitchMillimeters
        var needsRedraw = false

        if context.coordinator.appliedScalingMode != display.scalingMode {
            renderer.scalingMode = display.scalingMode
            context.coordinator.appliedScalingMode = display.scalingMode
            needsRedraw = true
        }
        if context.coordinator.appliedFilterMode != display.filterMode {
            renderer.filterMode = display.filterMode
            context.coordinator.appliedFilterMode = display.filterMode
            needsRedraw = true
        }
        if context.coordinator.appliedReflection != display.bezelReflection {
            renderer.reflectionEnabled = display.bezelReflection
            context.coordinator.appliedReflection = display.bezelReflection
            needsRedraw = true
        }
        if context.coordinator.appliedSignalLevel != signalLevel {
            renderer.signalLevel = signalLevel
            context.coordinator.appliedSignalLevel = signalLevel
            needsRedraw = true
        }
        if context.coordinator.appliedCRTScreenColor != display.crtScreenColor {
            renderer.crtScreenColor = display.crtScreenColor
            context.coordinator.appliedCRTScreenColor = display.crtScreenColor
            needsRedraw = true
        }
        if context.coordinator.appliedCRTDirtyGlass != display.crtDirtyGlass {
            renderer.crtDirtyGlass = display.crtDirtyGlass
            context.coordinator.appliedCRTDirtyGlass = display.crtDirtyGlass
            needsRedraw = true
        }
        if context.coordinator.appliedDotPitch != dotPitch {
            renderer.monitorDotPitchMillimeters = dotPitch
            context.coordinator.appliedDotPitch = dotPitch
            needsRedraw = true
        }
        if context.coordinator.appliedBezelSurfaceMode != bezelSurfaceMode {
            renderer.bezelSurfaceMode = bezelSurfaceMode
            context.coordinator.appliedBezelSurfaceMode = bezelSurfaceMode
            needsRedraw = true
        }
        // Picture/optics controls are live references the renderer reads
        // every frame; only bind once — knob drags must not force
        // SwiftUI/Metal churn.
        if renderer.picture !== display.picture {
            renderer.picture = display.picture
        }
        if renderer.optics !== display.optics {
            renderer.optics = display.optics
        }
        if context.coordinator.appliedPalette != display.palette {
            renderer.setPalette(C64Palette.palette(for: display.palette))
            context.coordinator.appliedPalette = display.palette
            needsRedraw = true
        }

        let animationChanged = renderer.updateAnimationState()
        if needsRedraw && !animationChanged {
            renderer.requestRedraw()
        }

        let captureEnabled = settings.captureKeyboardWhenFocused
        if nsView.captureEnabled != captureEnabled {
            nsView.captureEnabled = captureEnabled
        }
    }

    final class Coordinator {
        let session: DeviceSession
        var renderer: MetalFrameRenderer?
        var appliedScalingMode: ScalingMode?
        var appliedFilterMode: FilterMode?
        var appliedReflection: Bool?
        var appliedSignalLevel: Float?
        var appliedCRTScreenColor: CRTScreenColor?
        var appliedCRTDirtyGlass: Bool?
        var appliedDotPitch: Float?
        var appliedBezelSurfaceMode: Float?
        var appliedPalette: PaletteChoice?

        init(session: DeviceSession) {
            self.session = session
        }
    }
}

/// MTKView subclass that becomes first responder and forwards keystrokes
/// to the C64 as keyboard input. Also keeps rendering while the window is
/// occluded (MTKView's display link pauses then, which made background
/// playback jumpy) by driving draw() from a timer.
final class KeyCapturingMTKView: MTKView {
    var onKeyDown: ((HostKeyInput) -> Bool)?
    var onKeyUp: ((HostKeyInput) -> Bool)?
    var onFlagsChanged: ((UInt16, NSEvent.ModifierFlags) -> Bool)?
    var onFocusLost: (() -> Void)?
    var captureEnabled = true {
        didSet {
            if oldValue && !captureEnabled { onFocusLost?() }
        }
    }

    private var occlusionObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var backgroundTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            resignKeyObserver = nil
        }
        stopBackgroundDriving()
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            if window.occlusionState.contains(.visible) {
                self.stopBackgroundDriving()
            } else {
                self.startBackgroundDriving()
            }
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in self?.onFocusLost?() }
        if resignActiveObserver == nil {
            resignActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp, queue: .main
            ) { [weak self] _ in self?.onFocusLost?() }
        }
    }

    /// While occluded, MTKView's display link stops; drive draws manually
    /// at the stream rate so frames keep presenting.
    private func startBackgroundDriving() {
        guard backgroundTimer == nil else { return }
        // Drive slightly above PAL and at NTSC content rate so occluded
        // viewers keep presenting for either video standard.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.draw()
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    private func stopBackgroundDriving() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    deinit {
        backgroundTimer?.invalidate()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        onFocusLost?()
    }

    override func keyDown(with event: NSEvent) {
        guard captureEnabled else {
            super.keyDown(with: event)
            return
        }
        let input = Self.hostInput(event)
        guard onKeyDown?(input) == true else {
            super.keyDown(with: event)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        guard captureEnabled, onKeyUp?(Self.hostInput(event)) == true else {
            super.keyUp(with: event)
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard captureEnabled,
              onFlagsChanged?(
                event.keyCode,
                event.modifierFlags.intersection(
                    .deviceIndependentFlagsMask)) == true else {
            super.flagsChanged(with: event)
            return
        }
    }

    override func resignFirstResponder() -> Bool {
        onFocusLost?()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private static func hostInput(_ event: NSEvent) -> HostKeyInput {
        HostKeyInput(
            keyCode: event.keyCode,
            characters: event.characters,
            modifiers: event.modifierFlags.intersection(
                .deviceIndependentFlagsMask),
            isRepeat: event.isARepeat)
    }
}
