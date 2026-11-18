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
    @ObservedObject private var paletteLibrary = PaletteLibrary.shared
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
        context.coordinator.session.attachRendererDiagnostics { [weak renderer] in
            renderer?.diagnosticsSnapshot()
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
                context.coordinator.session.input.releaseAllIfNeeded()
            }
        }
        view.mouseCaptureAllowed = {
            MainActor.assumeIsolated {
                context.coordinator.session.isConnected
                    && context.coordinator.session.input.canCaptureMouse
            }
        }
        view.onMouseMotion = { x, y in
            MainActor.assumeIsolated { context.coordinator.session.input.moveMouse(x: x, y: y) }
        }
        view.onMouseScroll = { horizontal, vertical in
            MainActor.assumeIsolated {
                context.coordinator.session.input.scrollMouse(horizontal: horizontal, vertical: vertical)
            }
        }
        view.onMouseButton = { button, pressed in
            MainActor.assumeIsolated { context.coordinator.session.input.mouseButton(button, pressed: pressed) }
        }
        view.onMouseEscape = {
            MainActor.assumeIsolated { context.coordinator.session.input.settings.mouseEnabled = false }
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
        context.coordinator.session.filteredRecordingOutputSize = {
            [weak renderer] size in
            renderer?.filteredRecordingOutputSize(for: size)
        }
        context.coordinator.session.startFilteredRecording = {
            [weak renderer] size, makePixelBuffer, consume in
            renderer?.startFilteredRecording(
                size: size,
                makePixelBuffer: makePixelBuffer,
                consume: consume) ?? false
        }
        context.coordinator.session.stopFilteredRecording = { [weak renderer] in
            renderer?.stopFilteredRecording()
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
        let palette = display.resolvedPalette
        if context.coordinator.appliedPalette != palette {
            renderer.setPalette(palette)
            context.coordinator.appliedPalette = palette
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
        var appliedPalette: [SIMD4<UInt8>]?

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
    var mouseCaptureAllowed: (() -> Bool)?
    var onMouseMotion: ((Double, Double) -> Void)?
    var onMouseScroll: ((Double, Double) -> Void)?
    var onMouseButton: ((String, Bool) -> Void)?
    var onMouseEscape: (() -> Void)?
    private var mouseTrackingArea: NSTrackingArea?

    private var capturesMouse: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
            && mouseCaptureAllowed?() == true
    }

    @discardableResult
    func releaseMouseCaptureIfNeeded() -> Bool {
        guard capturesMouse else { return false }
        onMouseEscape?()
        onFocusLost?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = mouseTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if capturesMouse && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onMouseMotion?(event.deltaX, event.deltaY)
        }
        else if capturesMouse { onFocusLost?() }
        else { super.mouseMoved(with: event) }
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        if capturesMouse { onFocusLost?() }
        super.mouseExited(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if capturesMouse { onMouseButton?("left", false) }
        else { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Option-right-click retains access to Stream64's context menu.
        if capturesMouse && !event.modifierFlags.contains(.option) { onMouseButton?("right", true) }
        else { onFocusLost?(); super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if capturesMouse { onMouseButton?("right", false) }
        else { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if capturesMouse && event.buttonNumber == 2 { onMouseButton?("middle", true) }
        else { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if capturesMouse && event.buttonNumber == 2 { onMouseButton?("middle", false) }
        else { super.otherMouseUp(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard capturesMouse else { super.scrollWheel(with: event); return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        // Trackpad pixel deltas become detents; ordinary wheels already report
        // line-sized deltas. Momentum is ignored to avoid delayed C64 input.
        guard event.momentumPhase.isEmpty else { return }
        let scale = event.hasPreciseScrollingDeltas ? 0.1 : 1.0
        onMouseScroll?(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale)
    }
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
        window.acceptsMouseMovedEvents = true
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
        if event.keyCode == 53 && releaseMouseCaptureIfNeeded() {
            return
        }
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
        if capturesMouse { onMouseButton?("left", true) }
        else { super.mouseDown(with: event) }
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
