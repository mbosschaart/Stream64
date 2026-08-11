import Foundation
import simd

/// Pure scaling math for the live VIC frame. Kept free of Metal so unit
/// tests can cover the integer-mode utilization fallback without a GPU.
enum VideoScaling {
    /// PAL VIC stream height in pixels.
    static let frameHeight: Float = 272
    /// Authentic television aspect (C64 pixels are not square).
    static let displayAspect: Float = 4.0 / 3.0
    /// If the largest whole-pixel scale uses less than this fraction of the
    /// aspect-fit height, Integer mode falls back to Fit so fullscreen on
    /// awkward window sizes does not look needlessly tiny.
    static let integerMinUtilization: Float = 0.72

    /// Drawable → shader scale factors for the given mode.
    static func scaleFactors(
        mode: ScalingMode,
        drawableSize: CGSize
    ) -> SIMD2<Float> {
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return .one
        }
        let viewW = Float(drawableSize.width)
        let viewH = Float(drawableSize.height)

        switch mode {
        case .fill:
            return SIMD2<Float>(1, 1)
        case .aspectFit:
            return aspectFitFactors(viewWidth: viewW, viewHeight: viewH)
        case .integer:
            if let scale = integerScaleFactor(
                viewWidth: viewW, viewHeight: viewH)
            {
                let outH = frameHeight * scale
                return SIMD2<Float>(
                    outH * displayAspect / viewW, outH / viewH)
            }
            return aspectFitFactors(viewWidth: viewW, viewHeight: viewH)
        }
    }

    /// Largest whole-pixel scale that fits, or `nil` when that scale wastes
    /// so much of the window that Fit is a better choice.
    static func integerScaleFactor(
        viewWidth: Float,
        viewHeight: Float,
        frameHeight: Float = frameHeight,
        displayAspect: Float = displayAspect,
        minUtilization: Float = integerMinUtilization
    ) -> Float? {
        guard viewWidth > 0, viewHeight > 0, frameHeight > 0 else {
            return nil
        }
        let maxScale = min(
            viewHeight / frameHeight,
            viewWidth / (frameHeight * displayAspect))
        let integerScale = max(1, floor(maxScale))
        let fitHeight = min(viewHeight, viewWidth / displayAspect)
        let integerHeight = frameHeight * integerScale
        if integerHeight + 0.5 < fitHeight * minUtilization {
            return nil
        }
        return integerScale
    }

    private static func aspectFitFactors(
        viewWidth: Float,
        viewHeight: Float
    ) -> SIMD2<Float> {
        let outH = min(viewHeight, viewWidth / displayAspect)
        return SIMD2<Float>(
            outH * displayAspect / viewWidth, outH / viewHeight)
    }
}
