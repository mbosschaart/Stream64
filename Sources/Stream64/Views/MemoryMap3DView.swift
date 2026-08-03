import SwiftUI
import MetalKit

private final class MemoryMap3DHoverLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Stable bridge used by the Debug Trace toolbar's Reset View button. It is
/// intentionally not observable: camera actions redraw Metal directly and
/// should not rebuild the surrounding SwiftUI window.
final class MemoryMap3DInteraction {
    weak var renderer: MemoryMap3DRenderer?

    func resetCamera() {
        renderer?.resetCamera()
    }
}

struct MemoryMap3DView: NSViewRepresentable {
    let heatmap: MemoryHeatmap
    let source: DebugStreamSource
    let options: MemoryMap3DOptions
    let interaction: MemoryMap3DInteraction

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MemoryMap3DMTKView {
        let view = MemoryMap3DMTKView(frame: .zero, device: nil)
        let renderer = MemoryMap3DRenderer(
            mtkView: view,
            heatmap: heatmap)
        renderer?.source = source
        renderer?.options = options
        context.coordinator.renderer = renderer
        view.memoryRenderer = renderer
        interaction.renderer = renderer
        return view
    }

    func updateNSView(
        _ nsView: MemoryMap3DMTKView,
        context: Context
    ) {
        context.coordinator.renderer?.heatmap = heatmap
        context.coordinator.renderer?.source = source
        context.coordinator.renderer?.options = options
        if !options.hoverInspection {
            nsView.hideHoverInspection()
        }
        interaction.renderer = context.coordinator.renderer
    }

    static func dismantleNSView(
        _ nsView: MemoryMap3DMTKView,
        coordinator: Coordinator
    ) {
        coordinator.renderer?.stop()
        nsView.memoryRenderer = nil
    }

    final class Coordinator {
        var renderer: MemoryMap3DRenderer?
    }
}

/// Direct AppKit gestures keep camera interaction out of SwiftUI's state and
/// publication system. Drag orbits, scroll/pinch zooms, double-click resets.
final class MemoryMap3DMTKView: MTKView {
    weak var memoryRenderer: MemoryMap3DRenderer?
    private var trackingAreaReference: NSTrackingArea?
    private let hoverLabel: NSTextField = {
        let label = MemoryMap3DHoverLabel(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        label.drawsBackground = true
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.isHidden = true
        return label
    }()

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        addSubview(hoverLabel)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(hoverLabel)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            memoryRenderer?.resetCamera()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        memoryRenderer?.rotate(
            deltaX: Float(event.deltaX),
            deltaY: Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        memoryRenderer?.zoom(
            scrollDelta: Float(event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        memoryRenderer?.magnify(Float(event.magnification))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved, .mouseEnteredAndExited,
                .activeInKeyWindow, .inVisibleRect,
            ],
            owner: self,
            userInfo: nil)
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let inspection = memoryRenderer?.inspect(
            point: point,
            in: self)
        else {
            hoverLabel.isHidden = true
            return
        }

        hoverLabel.stringValue = String(
            format: "$%04X  $%02X  %@  %@",
            inspection.address,
            inspection.value,
            inspection.wasRead ? "READ" : "WRITE",
            inspection.region)
        hoverLabel.sizeToFit()
        var frame = hoverLabel.frame
        frame.size.width += 12
        frame.size.height += 6
        frame.origin.x = min(
            max(6, point.x + 12),
            max(6, bounds.width - frame.width - 6))
        frame.origin.y = min(
            max(6, point.y + 12),
            max(6, bounds.height - frame.height - 6))
        hoverLabel.frame = frame
        hoverLabel.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverLabel.isHidden = true
    }

    func hideHoverInspection() {
        hoverLabel.isHidden = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
