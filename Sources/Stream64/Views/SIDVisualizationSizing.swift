import SwiftUI

/// Applies one consistent logical-to-window scale to legacy instrument views.
/// Fonts, fixed gutters, legends and their layout space grow together; flexible
/// plots still fill the available aspect ratio. Existing responsive effects
/// render at native size so they are never scaled twice.
struct SIDVisualizationSizing<Content: View>: View {
    let mode: SIDVisualizationMode
    let chipCount: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let scale = SIDVisualizationScale.factor(mode: mode, chipCount: chipCount,
                                                     size: geometry.size)
            content()
                .frame(width: geometry.size.width / scale,
                       height: geometry.size.height / scale)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

enum SIDVisualizationScale {
    static func factor(mode: SIDVisualizationMode, chipCount: Int, size: CGSize) -> CGFloat {
        if mode.isGenerative { return 1 }
        switch mode {
        // These views already size their typography from their own geometry.
        case .registerActivity, .controlBits, .dashboard, .kaos, .sidShowcase, .clubMode:
            return 1
        // Pure graphics without labels need no typography/layout adjustment.
        case .spectrum, .lissajous, .waterfall3D, .barField3D, .colorfulWaveform:
            return 1
        default:
            // Extra vertical room is needed for two rows of voice panels.
            // Never shrink existing compact-window typography or cap fullscreen growth.
            return max(1, SIDPanelSizing.scale(in: size,
                reference: CGSize(width: 900, height: chipCount > 1 ? 600 : 400)))
        }
    }
}
