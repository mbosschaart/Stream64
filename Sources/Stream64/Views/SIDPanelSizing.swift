import SwiftUI

/// Proportional sizing without an upper cap: fullscreen scales text and
/// indicators together. Use the smaller axis so narrow/short windows still fit.
enum SIDPanelSizing {
    static func scale(in size: CGSize, reference: CGSize) -> CGFloat {
        max(0.01, min(max(0, size.width) / reference.width,
                      max(0, size.height) / reference.height))
    }
}
