import AppKit
import ObjectiveC
import SwiftUI

/// Keeps Stream64 windows independently full-screenable on their own Spaces.
///
/// Secondary windows often open as guests on the viewer's full-screen Space.
/// A normal `toggleFullScreen` then *promotes them in place* (same Space /
/// Split View) instead of creating a new Mission Control Space. This policy
/// forces `fullScreenPrimary`, strips guest/join-all flags, and detaches from
/// a foreign full-screen Space before entering full screen.
///
/// Covers **all** titled/resizable windows (SwiftUI scenes and AppKit tool
/// windows) via launch-time `NSWindow` swizzles on `toggleFullScreen:` and
/// `performZoom:`, plus observers / `.independentFullScreenWindow()`.
enum Stream64WindowPolicy {
    @MainActor
    private static var didInstallSwizzles = false
    /// Concrete subclasses whose `toggleFullScreen:` was exchanged with our
    /// hook (SwiftUI scene windows override it and bypass the NSWindow swizzle).
    @MainActor
    private static var subclassExchangedNames = Set<String>()
    /// Classes we already inspected (avoid repeat work).
    @MainActor
    private static var inspectedClassNames = Set<String>()

    /// Install once from `applicationWillFinishLaunching`.
    @MainActor
    static func install() {
        guard !didInstallSwizzles else { return }
        didInstallSwizzles = true
        NSWindow.stream64_installOwnSpaceSwizzles()
        inspectedClassNames.insert(NSStringFromClass(NSWindow.self))
    }

    /// Absolute primary-Space behavior — do not merge with existing flags
    /// (SwiftUI / AppKit may have left `fullScreenAuxiliary` or join-all).
    @MainActor
    static func applyIndependentFullScreenSupport(to window: NSWindow) {
        guard shouldManage(window) else { return }

        hookConcreteClassIfNeeded(window)

        window.collectionBehavior = [
            .fullScreenPrimary,
            .fullScreenDisallowsTiling,
            .managed,
        ]
        window.tabbingMode = .disallowed

        // Route green button through our coordinator — never the window's
        // own `toggleFullScreen:` (SwiftUI subclasses bypass the NSWindow
        // swizzle). Re-bind every apply; AppKit resets traffic lights when
        // hosting attaches.
        if let zoom = window.standardWindowButton(.zoomButton) {
            zoom.target = FullScreenSpaceCoordinator.shared
            zoom.action = #selector(FullScreenSpaceCoordinator.zoomToOwnSpace(_:))
        }
    }

    /// SwiftUI `Window` / `WindowGroup` use private NSWindow subclasses that
    /// override `toggleFullScreen:`. Hook each concrete class once.
    @MainActor
    private static func hookConcreteClassIfNeeded(_ window: NSWindow) {
        let cls: AnyClass = object_getClass(window) ?? NSWindow.self
        let name = NSStringFromClass(cls)
        guard !inspectedClassNames.contains(name) else { return }
        inspectedClassNames.insert(name)
        guard cls != NSWindow.self else { return }

        let originalSel = #selector(NSWindow.toggleFullScreen(_:))
        let hookSel = #selector(NSWindow.stream64_subclassToggleFullScreen(_:))
        guard
            let nsToggle = class_getInstanceMethod(NSWindow.self, originalSel),
            let originalMethod = class_getInstanceMethod(cls, originalSel),
            let hookTemplate = class_getInstanceMethod(NSWindow.self, hookSel),
            // Only when the subclass actually overrides (different IMP).
            method_getImplementation(originalMethod)
                != method_getImplementation(nsToggle)
        else { return }

        class_addMethod(
            cls,
            hookSel,
            method_getImplementation(hookTemplate),
            method_getTypeEncoding(hookTemplate))
        guard let hookMethod = class_getInstanceMethod(cls, hookSel) else {
            return
        }
        method_exchangeImplementations(originalMethod, hookMethod)
        subclassExchangedNames.insert(name)
    }

    /// Enter / exit full screen on a dedicated Space (green button + menu).
    @MainActor
    static func toggleOwnFullScreenSpace(for window: NSWindow) {
        applyIndependentFullScreenSupport(to: window)
        handleToggleFullScreen(window, sender: nil)
    }

    @MainActor
    fileprivate static func shouldManage(_ window: NSWindow) -> Bool {
        if window.styleMask.contains(.borderless) { return false }
        if window.styleMask.contains(.utilityWindow) { return false }
        if window.level != .normal { return false }
        guard window.styleMask.contains(.titled) else { return false }
        guard window.styleMask.contains(.resizable) else { return false }
        return true
    }

    @MainActor
    fileprivate static func hasForeignFullScreenPeer(for window: NSWindow) -> Bool {
        NSApp.windows.contains {
            $0 !== window && $0.styleMask.contains(.fullScreen)
        }
    }

    /// Shared entry for every full-screen request (menu, green button, code).
    @MainActor
    fileprivate static func handleToggleFullScreen(
        _ window: NSWindow,
        sender: Any?
    ) {
        guard shouldManage(window) else {
            invokeOriginalToggleFullScreen(window, sender: sender)
            return
        }

        applyIndependentFullScreenSupport(to: window)

        if window.styleMask.contains(.fullScreen)
            || !hasForeignFullScreenPeer(for: window) {
            invokeOriginalToggleFullScreen(window, sender: sender)
            return
        }

        detachFromForeignSpaceThenFullScreen(window, sender: sender)
    }

    /// Call the pre-hook implementation (AppKit or SwiftUI subclass).
    @MainActor
    fileprivate static func invokeOriginalToggleFullScreen(
        _ window: NSWindow,
        sender: Any?
    ) {
        let cls: AnyClass = object_getClass(window) ?? NSWindow.self
        if subclassExchangedNames.contains(NSStringFromClass(cls)) {
            // After subclass exchange, this selector holds the original IMP.
            window.stream64_subclassToggleFullScreen(sender)
        } else {
            window.stream64_originalToggleFullScreen(sender)
        }
    }

    /// Break guest attachment to the viewer's Space, then full-screen so
    /// WindowServer allocates a *new* Space instead of promoting in place.
    @MainActor
    private static func detachFromForeignSpaceThenFullScreen(
        _ window: NSWindow,
        sender: Any?
    ) {
        applyIndependentFullScreenSupport(to: window)

        let wasVisible = window.isVisible
        let savedFrame = window.frame
        window.orderOut(nil)

        window.collectionBehavior = [
            .canJoinAllSpaces,
            .managed,
        ]
        if let screen = NSScreen.main {
            var frame = savedFrame
            let visible = screen.visibleFrame
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
            window.setFrame(frame, display: false)
        }
        window.orderFrontRegardless()

        DispatchQueue.main.async {
            window.collectionBehavior = [
                .fullScreenPrimary,
                .fullScreenDisallowsTiling,
                .managed,
            ]
            if wasVisible {
                window.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.async {
                invokeOriginalToggleFullScreen(window, sender: sender)
            }
        }
    }
}

/// Zoom-button target that cannot be bypassed by SwiftUI window subclasses.
@MainActor
private final class FullScreenSpaceCoordinator: NSObject {
    static let shared = FullScreenSpaceCoordinator()

    @objc func zoomToOwnSpace(_ sender: Any?) {
        let window = (sender as? NSView)?.window
            ?? (sender as? NSButton)?.window
            ?? NSApp.keyWindow
        guard let window else { return }
        Stream64WindowPolicy.toggleOwnFullScreenSpace(for: window)
    }
}

// MARK: - NSWindow swizzles (covers SwiftUI + AppKit windows)

extension NSWindow {
    fileprivate static func stream64_installOwnSpaceSwizzles() {
        let pairs: [(Selector, Selector)] = [
            (
                #selector(NSWindow.toggleFullScreen(_:)),
                #selector(NSWindow.stream64_swizzledToggleFullScreen(_:))
            ),
            (
                #selector(NSWindow.performZoom(_:)),
                #selector(NSWindow.stream64_swizzledPerformZoom(_:))
            ),
        ]
        for (original, swizzled) in pairs {
            guard
                let originalMethod = class_getInstanceMethod(NSWindow.self, original),
                let swizzledMethod = class_getInstanceMethod(NSWindow.self, swizzled)
            else { continue }
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }

    /// After install, invoking this selector runs AppKit's real implementation.
    @objc fileprivate func stream64_originalToggleFullScreen(_ sender: Any?) {
        stream64_swizzledToggleFullScreen(sender)
    }

    @objc fileprivate func stream64_swizzledToggleFullScreen(_ sender: Any?) {
        MainActor.assumeIsolated {
            Stream64WindowPolicy.handleToggleFullScreen(self, sender: sender)
        }
    }

    /// Hook body copied onto SwiftUI `NSWindow` subclasses, then exchanged
    /// with their `toggleFullScreen:` override.
    @objc fileprivate func stream64_subclassToggleFullScreen(_ sender: Any?) {
        MainActor.assumeIsolated {
            Stream64WindowPolicy.handleToggleFullScreen(self, sender: sender)
        }
    }

    /// Green button / Zoom → own-Space full screen for managed windows.
    @objc fileprivate func stream64_swizzledPerformZoom(_ sender: Any?) {
        MainActor.assumeIsolated {
            if Stream64WindowPolicy.shouldManage(self) {
                Stream64WindowPolicy.toggleOwnFullScreenSpace(for: self)
            } else {
                // Exchanged IMP — this call is AppKit's original performZoom.
                stream64_swizzledPerformZoom(sender)
            }
        }
    }
}

/// Hooks the hosting `NSWindow` as soon as SwiftUI attaches the view tree.
struct IndependentFullScreenWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(IndependentFullScreenWindowAccessor())
    }
}

extension View {
    /// Prefer each Stream64 window as its own full-screen Space candidate.
    func independentFullScreenWindow() -> some View {
        modifier(IndependentFullScreenWindowModifier())
    }
}

private struct IndependentFullScreenWindowAccessor: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {
        if let window = nsView.window {
            Stream64WindowPolicy.applyIndependentFullScreenSupport(to: window)
        }
    }
}
