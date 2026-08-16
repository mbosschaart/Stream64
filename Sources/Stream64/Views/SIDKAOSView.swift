import AppKit
import SwiftUI

/// Beat-cut acid-house/demoscene collage driven by the shared KAOS rhythm
/// state. Every layer is procedural or adapted from real SID analysis data;
/// no external imagery is needed.
struct SIDKAOSView: View {
    let rhythm: KAOSRhythmState
    let bars: [Float]
    let channels: [SIDVoiceChannel]
    let lissajousPoints: [(left: Float, right: Float)]
    var glow = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let bpm = max(75, min(180, Double(rhythm.inferredBPM == 0 ? 120 : rhythm.inferredBPM)))
                // Cut every eight beats; a bounded wall-clock fallback keeps
                // KAOS moving for sparse/noisy register patterns.
                let sceneDuration = 60 / bpm * 8
                let sceneStep = Int(time / sceneDuration)
                let scene = KAOSScene(
                    rawValue: shuffledSceneIndex(
                        step: sceneStep,
                        phrase: rhythm.phraseIndex,
                        count: KAOSScene.allCases.count)
                ) ?? .acidGrid
                let palette = KAOSPalette(
                    phase: time * 0.025
                        + Double(scene.rawValue) / Double(KAOSScene.allCases.count)
                        + Double(rhythm.barPhase) * 0.065
                        + Double(rhythm.bassEnergy - rhythm.midEnergy) * 0.11)

                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black))
                drawScanlines(context: &context, size: size)

                switch scene {
                case .acidGrid:
                    drawAcidGrid(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .wireTunnel:
                    drawTunnel(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .kaleidoscope:
                    drawKaleidoscope(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .scopeWall:
                    drawScopeWall(
                        context: &context, size: size, palette: palette)
                case .vuMatrix:
                    drawVUMatrix(
                        context: &context, size: size, time: time,
                        sceneStep: sceneStep, palette: palette)
                case .noiseStorm:
                    drawNoiseStorm(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .chromaWipe:
                    drawChromaWipe(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .dancers:
                    drawDancers(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .c64Wireframe:
                    drawC64Wireframe(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .floppy:
                    drawFloppy(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .acidOrbs:
                    drawAcidOrbs(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .cassette:
                    drawCassetteDeck(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .cityscape:
                    drawCityscape(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .hyperspace:
                    drawHyperspace(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .rasterStorm:
                    drawRasterStorm(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .checkerboard:
                    drawCheckerboard(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .turntable:
                    drawTurntable(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .ribbon:
                    drawRibbon(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .cubes:
                    drawCubes(
                        context: &context, size: size, time: time,
                        palette: palette)
                case .smiley:
                    drawAssetScene(
                        context: &context, size: size, time: time,
                        asset: Self.smileyAsset, palette: palette)
                case .joystick:
                    drawAssetScene(
                        context: &context, size: size, time: time,
                        asset: Self.joystickAsset, palette: palette)
                case .drive:
                    drawAssetScene(
                        context: &context, size: size, time: time,
                        asset: Self.driveAsset, palette: palette)
                case .monitor:
                    drawAssetScene(
                        context: &context, size: size, time: time,
                        asset: Self.monitorAsset, palette: palette)
                }

                drawSpectrum(
                    context: &context, size: size, palette: palette)
                drawLissajousOrbit(
                    context: &context, size: size, palette: palette)
                drawBeatRays(
                    context: &context, size: size, time: time,
                    palette: palette)
                drawTypography(
                    context: &context, size: size, time: time,
                    sceneStep: sceneStep, palette: palette)
                drawBeatFlash(
                    context: &context, size: size, palette: palette)
            }
        }
        .background(.black)
    }

    // MARK: - Scene library

    private enum KAOSScene: Int, CaseIterable {
        case acidGrid, wireTunnel, kaleidoscope, scopeWall
        case vuMatrix, noiseStorm, chromaWipe
        case dancers, c64Wireframe, floppy, acidOrbs
        case cassette, cityscape, hyperspace, rasterStorm
        case checkerboard, turntable, ribbon, cubes
        case smiley, joystick, drive, monitor
    }

    private static let floppyAsset = lineArt(named: "kaos-floppy")
    private static let cassetteAsset = lineArt(named: "kaos-cassette")
    private static let smileyAsset = lineArt(named: "kaos-smiley")
    private static let joystickAsset = lineArt(named: "kaos-joystick")
    private static let c64Asset = lineArt(named: "kaos-c64")
    private static let driveAsset = lineArt(named: "kaos-1541")
    private static let monitorAsset = lineArt(named: "kaos-monitor")

    private struct KAOSPalette {
        let hotPink: Color
        let cyan: Color
        let acid: Color
        let violet: Color
        let amber: Color

        init(phase: Double) {
            let hue = phase - phase.rounded(.down)
            hotPink = Color(hue: hue, saturation: 0.9, brightness: 1)
            cyan = Color(hue: (hue + 0.48).truncatingRemainder(dividingBy: 1),
                         saturation: 0.78, brightness: 1)
            acid = Color(hue: (hue + 0.25).truncatingRemainder(dividingBy: 1),
                         saturation: 0.92, brightness: 1)
            violet = Color(hue: (hue + 0.78).truncatingRemainder(dividingBy: 1),
                           saturation: 0.75, brightness: 1)
            amber = Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1),
                          saturation: 0.85, brightness: 1)
        }
    }

    private func shuffledSceneIndex(step: Int, phrase: Int, count: Int) -> Int {
        // Coprime stride gives every scene a turn before repeating; the
        // phrase term changes the route through that cycle on each phrase.
        let stride = count > 1 ? count - 2 : 1
        return (step * stride + phrase * 7 + phrase * phrase * 3) % count
    }

    private static func lineArt(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        guard !ResourceBundle.isPackagedApp,
              let url = Bundle.module.url(forResource: name, withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    private func drawAcidGrid(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let horizon = size.height * (0.34 - CGFloat(rhythm.beatPulse) * 0.06)
        var path = Path()
        let columns = 18
        for column in 0...columns {
            let x = size.width * CGFloat(column) / CGFloat(columns)
            path.move(to: CGPoint(x: size.width / 2, y: horizon))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        let scroll = CGFloat((time * 0.42).truncatingRemainder(dividingBy: 1))
        for row in 1...15 {
            let t = (CGFloat(row) / 15 + scroll).truncatingRemainder(dividingBy: 1)
            let y = horizon + (size.height - horizon) * t * t
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        strokeGlow(context: &context, path: path, color: palette.cyan)
        let orbit = CGFloat(sin(time * 1.7)) * 0.12 + 0.5
        let sun = CGRect(
            x: size.width * (orbit - 0.12),
            y: horizon - size.width * 0.12,
            width: size.width * 0.24,
            height: size.width * 0.24)
        context.fill(Path(ellipseIn: sun), with: .color(palette.hotPink))
    }

    private func drawTunnel(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = hypot(size.width, size.height) * 0.7
        for ring in 0..<11 {
            let phase = CGFloat((time * 1.5).truncatingRemainder(dividingBy: 1))
            let t = (CGFloat(ring) + phase) / 11
            let radius = maxRadius * t * t
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color((ring.isMultiple(of: 2) ? palette.acid : palette.violet)
                    .opacity(0.32 + Double(rhythm.beatPulse) * 0.45)),
                lineWidth: 1.5)
        }
        var spokes = Path()
        let angleOffset = time * 0.8
        for spoke in 0..<16 {
            let angle = angleOffset + Double(spoke) * .pi * 2 / 16
            spokes.move(to: center)
            spokes.addLine(to: CGPoint(
                x: center.x + CGFloat(Foundation.cos(angle)) * maxRadius,
                y: center.y + CGFloat(Foundation.sin(angle)) * maxRadius))
        }
        strokeGlow(context: &context, path: spokes, color: palette.cyan)
    }

    private func drawKaleidoscope(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.42
        for index in 0..<12 {
            let base = time * 0.7 + Double(index) * .pi * 2 / 12
            var path = Path()
            path.move(to: center)
            for point in 0...4 {
                let angle = base + Double(point) * .pi / 2
                let r = radius * (0.45 + 0.45 * CGFloat(
                    sin(time * 2.2 + Double(index + point))))
                path.addLine(to: CGPoint(
                    x: center.x + CGFloat(Foundation.cos(angle)) * r,
                    y: center.y + CGFloat(Foundation.sin(angle)) * r))
            }
            path.closeSubpath()
            context.stroke(
                path,
                with: .color(index.isMultiple(of: 2) ? palette.hotPink : palette.acid),
                lineWidth: 2)
        }
    }

    private func drawScopeWall(
        context: inout GraphicsContext,
        size: CGSize,
        palette: KAOSPalette
    ) {
        let rows = 2
        let columns = 3
        let cell = CGSize(width: size.width / CGFloat(columns), height: size.height / CGFloat(rows))
        for (index, channel) in channels.prefix(6).enumerated() {
            let rect = CGRect(
                x: CGFloat(index % columns) * cell.width,
                y: CGFloat(index / columns) * cell.height,
                width: cell.width,
                height: cell.height)
                .insetBy(dx: 8, dy: 8)
            context.stroke(Path(rect), with: .color(.white.opacity(0.18)), lineWidth: 1)
            let samples = channel.orderedSamples
            guard samples.count > 1 else { continue }
            var path = Path()
            for (sampleIndex, sample) in samples.enumerated() {
                let x = rect.minX + rect.width * CGFloat(sampleIndex) / CGFloat(samples.count - 1)
                let y = rect.midY - CGFloat(sample) * (rect.height * 0.38)
                sampleIndex == 0
                    ? path.move(to: CGPoint(x: x, y: y))
                    : path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(
                path,
                with: .color(index.isMultiple(of: 2) ? palette.cyan : palette.hotPink),
                lineWidth: 1.2)
        }
    }

    private func drawVUMatrix(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        sceneStep: Int,
        palette: KAOSPalette
    ) {
        let levels = rhythm.voiceLevels
        let layout = sceneStep % 4
        let count = max(1, levels.count)
        for index in levels.indices {
            let level = min(1, CGFloat(levels[index]) * 4.5)
            let bar: CGRect
            switch layout {
            case 0: // classic full-height vertical bridge
                let width = size.width / CGFloat(count)
                bar = CGRect(
                    x: CGFloat(index) * width + width * 0.18,
                    y: size.height * (1 - level) + 28,
                    width: width * 0.64,
                    height: max(3, size.height * level - 36))
            case 1: // left-to-right acid bars
                let height = size.height / CGFloat(count)
                bar = CGRect(
                    x: 18,
                    y: CGFloat(index) * height + height * 0.18,
                    width: max(3, (size.width - 36) * level),
                    height: height * 0.64)
            case 2: // top/bottom mirrored
                let width = size.width / CGFloat(count)
                let height = size.height * level * 0.42
                bar = CGRect(
                    x: CGFloat(index) * width + width * 0.18,
                    y: size.height / 2 - height,
                    width: width * 0.64,
                    height: max(3, height * 2))
            default: // rotating corner meters
                let radius = min(size.width, size.height) * 0.32
                let angle = time * 0.9 + Double(index) * .pi * 2 / Double(count)
                let length = radius * level
                bar = CGRect(
                    x: size.width / 2 + CGFloat(Foundation.cos(angle)) * length - 10,
                    y: size.height / 2 + CGFloat(Foundation.sin(angle)) * length - 10,
                    width: 20,
                    height: 20)
            }
            context.fill(
                Path(roundedRect: bar, cornerRadius: 4),
                with: .linearGradient(
                    Gradient(colors: [palette.cyan, palette.acid, palette.hotPink]),
                    startPoint: CGPoint(x: bar.midX, y: bar.maxY),
                    endPoint: CGPoint(x: bar.midX, y: bar.minY)))
        }
    }

    private func drawNoiseStorm(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let count = 90
        for index in 0..<count {
            let phase = Double(index) * 12.9898 + time * 21.7
            let x = CGFloat(sin(phase) * 0.5 + 0.5) * size.width
            let y = CGFloat(sin(phase * 1.7) * 0.5 + 0.5) * size.height
            let r = CGFloat(1 + abs(sin(phase * 2)) * 5)
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                with: .color((index.isMultiple(of: 2) ? palette.acid : palette.hotPink)
                    .opacity(0.18 + Double(rhythm.digiActivity) * 0.5)))
        }
    }

    private func drawChromaWipe(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let offset = CGFloat((time * 0.18).truncatingRemainder(dividingBy: 1))
        for index in 0..<9 {
            let x = (CGFloat(index) / 9 + offset).truncatingRemainder(dividingBy: 1) * size.width
            let rect = CGRect(x: x, y: 0, width: size.width / 12, height: size.height)
            context.fill(
                Path(rect),
                with: .color(index.isMultiple(of: 2) ? palette.violet.opacity(0.55) : palette.cyan.opacity(0.42)))
        }
    }

    private func drawDancers(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let count = 5
        let floor = size.height * 0.78
        for index in 0..<count {
            let x = size.width * CGFloat(index + 1) / CGFloat(count + 1)
            let phase = time * 5.5 + Double(index) * 1.7
            let bounce = CGFloat(abs(Foundation.sin(phase))) * (30 + CGFloat(rhythm.beatPulse) * 45)
            let head = CGPoint(x: x, y: floor - 120 - bounce)
            var body = Path()
            body.addEllipse(in: CGRect(x: head.x - 12, y: head.y - 12, width: 24, height: 24))
            body.move(to: CGPoint(x: head.x, y: head.y + 12))
            body.addLine(to: CGPoint(x: head.x, y: floor - 45 - bounce))
            let arm = CGFloat(Foundation.sin(phase * 1.8)) * 34
            body.move(to: CGPoint(x: head.x, y: head.y + 42))
            body.addLine(to: CGPoint(x: head.x + arm, y: head.y + 68))
            body.move(to: CGPoint(x: head.x, y: head.y + 42))
            body.addLine(to: CGPoint(x: head.x - arm, y: head.y + 68))
            let leg = CGFloat(Foundation.sin(phase * 1.3)) * 26
            body.move(to: CGPoint(x: head.x, y: floor - 45 - bounce))
            body.addLine(to: CGPoint(x: head.x + leg, y: floor - bounce))
            body.move(to: CGPoint(x: head.x, y: floor - 45 - bounce))
            body.addLine(to: CGPoint(x: head.x - leg, y: floor - bounce))
            strokeGlow(
                context: &context,
                path: body,
                color: index.isMultiple(of: 2) ? palette.acid : palette.hotPink)
        }
    }

    private func drawC64Wireframe(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        if drawLineArt(
            context: &context,
            size: size,
            asset: Self.c64Asset,
            time: time,
            palette: palette,
            widthFraction: 0.86
        ) { return }
        let center = CGPoint(x: size.width / 2, y: size.height * 0.53)
        let scale = min(size.width, size.height) * 0.34
        let tilt = CGFloat(Foundation.sin(time * 0.8)) * 0.25
        let left = center.x - scale
        let right = center.x + scale
        let frontY = center.y + scale * 0.42
        let rearY = center.y - scale * 0.32 + tilt * scale
        // The C64's characteristic wedge: broad front keyboard lip, shallow
        // rear case, and a raised right-side vent/badge area.
        var wire = Path()
        wire.move(to: CGPoint(x: left, y: frontY))
        wire.addLine(to: CGPoint(x: right, y: frontY))
        wire.addLine(to: CGPoint(x: right - scale * 0.08, y: rearY))
        wire.addLine(to: CGPoint(x: left + scale * 0.08, y: rearY))
        wire.closeSubpath()

        let keyboardTop = rearY + scale * 0.16
        let keyboardBottom = frontY - scale * 0.12
        let keyboardLeft = left + scale * 0.12
        let keyboardRight = center.x + scale * 0.42
        wire.addRect(CGRect(
            x: keyboardLeft, y: keyboardTop,
            width: keyboardRight - keyboardLeft,
            height: keyboardBottom - keyboardTop))
        for row in 1...4 {
            let y = keyboardTop + (keyboardBottom - keyboardTop) * CGFloat(row) / 5
            wire.move(to: CGPoint(x: keyboardLeft, y: y))
            wire.addLine(to: CGPoint(x: keyboardRight, y: y))
        }
        for column in 1...11 {
            let x = keyboardLeft + (keyboardRight - keyboardLeft) * CGFloat(column) / 12
            wire.move(to: CGPoint(x: x, y: keyboardTop))
            wire.addLine(to: CGPoint(x: x, y: keyboardBottom))
        }
        // Right-side speaker/vent stripes and small Commodore-style badge.
        let ventLeft = center.x + scale * 0.55
        for stripe in 0..<6 {
            let y = rearY + scale * (0.13 + CGFloat(stripe) * 0.055)
            wire.move(to: CGPoint(x: ventLeft, y: y))
            wire.addLine(to: CGPoint(x: right - scale * 0.16, y: y))
        }
        wire.addRect(CGRect(
            x: left + scale * 0.14, y: rearY + scale * 0.08,
            width: scale * 0.16, height: scale * 0.07))
        strokeGlow(context: &context, path: wire, color: palette.cyan)
    }

    private func drawFloppy(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        if drawLineArt(
            context: &context,
            size: size,
            asset: Self.floppyAsset,
            time: time,
            palette: palette,
            widthFraction: 0.52
        ) { return }
        let side = min(size.width, size.height) * (0.42 + CGFloat(rhythm.beatPulse) * 0.08)
        let rect = CGRect(
            x: size.width / 2 - side / 2,
            y: size.height / 2 - side / 2,
            width: side,
            height: side)
        var disk = Path(roundedRect: rect, cornerRadius: 12)
        // 3.5-inch floppy: metal shutter at top, label on the upper left,
        // and centered hub hole.
        let shutter = CGRect(
            x: rect.minX + side * 0.55, y: rect.minY,
            width: side * 0.3, height: side * 0.16)
        disk.addRect(shutter)
        let label = CGRect(x: rect.minX + side * 0.13, y: rect.minY + side * 0.19,
                           width: side * 0.48, height: side * 0.25)
        disk.addRect(label)
        let hub = CGRect(x: rect.midX - side * 0.13, y: rect.midY - side * 0.13,
                         width: side * 0.26, height: side * 0.26)
        disk.addEllipse(in: hub)
        var spunContext = context
        spunContext.translateBy(x: rect.midX, y: rect.midY)
        spunContext.rotate(by: Angle(radians: time * 0.45))
        spunContext.translateBy(x: -rect.midX, y: -rect.midY)
        strokeGlow(context: &spunContext, path: disk, color: palette.violet)
    }

    private func drawAcidOrbs(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        for index in 0..<18 {
            let phase = time * (0.7 + Double(index % 4) * 0.18) + Double(index)
            let radius = CGFloat(20 + (index % 5) * 13) * (1 + CGFloat(rhythm.beatPulse) * 0.6)
            let x = size.width * (0.5 + CGFloat(Foundation.sin(phase * 1.3)) * 0.42)
            let y = size.height * (0.5 + CGFloat(Foundation.cos(phase * 1.7)) * 0.36)
            let orb = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.fill(
                orb,
                with: .color((index.isMultiple(of: 2) ? palette.hotPink : palette.acid).opacity(0.35)))
            context.stroke(orb, with: .color(palette.cyan.opacity(0.8)), lineWidth: 1)
        }
    }

    private func drawCassetteDeck(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        if drawLineArt(
            context: &context,
            size: size,
            asset: Self.cassetteAsset,
            time: time,
            palette: palette,
            widthFraction: 0.78
        ) { return }
        let width = size.width * 0.66
        let height = width * 0.4
        let deck = CGRect(x: size.width / 2 - width / 2, y: size.height / 2 - height / 2,
                          width: width, height: height)
        var path = Path(roundedRect: deck, cornerRadius: 12)
        let label = CGRect(x: deck.minX + width * 0.12, y: deck.minY + height * 0.12,
                           width: width * 0.76, height: height * 0.26)
        path.addRect(label)
        let window = CGRect(x: deck.minX + width * 0.28, y: deck.minY + height * 0.49,
                            width: width * 0.44, height: height * 0.19)
        path.addRect(window)
        for x in [deck.minX + width * 0.24, deck.maxX - width * 0.24] {
            let reel = CGRect(x: x - height * 0.14, y: deck.maxY - height * 0.29,
                              width: height * 0.28, height: height * 0.28)
            path.addEllipse(in: reel)
            path.addEllipse(in: reel.insetBy(dx: height * 0.085, dy: height * 0.085))
        }
        for point in [
            CGPoint(x: deck.minX + 10, y: deck.minY + 10),
            CGPoint(x: deck.maxX - 10, y: deck.minY + 10),
            CGPoint(x: deck.minX + 10, y: deck.maxY - 10),
            CGPoint(x: deck.maxX - 10, y: deck.maxY - 10),
        ] {
            path.addEllipse(in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
        }
        var rotatedContext = context
        rotatedContext.translateBy(x: deck.midX, y: deck.midY)
        rotatedContext.rotate(by: Angle(radians: Foundation.sin(time * 0.7) * 0.12))
        rotatedContext.translateBy(x: -deck.midX, y: -deck.midY)
        strokeGlow(context: &rotatedContext, path: path, color: palette.amber)
    }

    private func drawCityscape(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let count = 22
        let width = size.width / CGFloat(count)
        for index in 0..<count {
            let energy = bars.isEmpty ? 0.4 : CGFloat(bars[index % bars.count])
            let height = size.height * (0.13 + min(0.58, energy * 0.9))
            let rect = CGRect(x: CGFloat(index) * width, y: size.height - height,
                              width: width - 2, height: height)
            context.fill(Path(rect), with: .color(index.isMultiple(of: 2) ? palette.violet.opacity(0.7) : palette.cyan.opacity(0.65)))
            if Int(time * 8 + Double(index)).isMultiple(of: 3) {
                context.fill(Path(CGRect(x: rect.midX - 2, y: rect.minY + 8, width: 4, height: 6)),
                             with: .color(palette.acid))
            }
        }
    }

    private func drawHyperspace(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var stars = Path()
        for index in 0..<90 {
            let seed = Double(index) * 43.17
            let angle = seed.truncatingRemainder(dividingBy: .pi * 2)
            let phase = (time * 1.6 + seed * 0.1).truncatingRemainder(dividingBy: 1)
            let inner = CGFloat(phase * phase) * min(size.width, size.height) * 0.08
            let outer = inner + 8 + CGFloat(rhythm.beatPulse) * 24
            stars.move(to: CGPoint(
                x: center.x + CGFloat(Foundation.cos(angle)) * inner,
                y: center.y + CGFloat(Foundation.sin(angle)) * inner))
            stars.addLine(to: CGPoint(
                x: center.x + CGFloat(Foundation.cos(angle)) * outer,
                y: center.y + CGFloat(Foundation.sin(angle)) * outer))
        }
        strokeGlow(context: &context, path: stars, color: palette.cyan)
    }

    private func drawRasterStorm(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let bandHeight: CGFloat = 14
        let offset = CGFloat((time * 95).truncatingRemainder(dividingBy: Double(bandHeight)))
        for index in -1...Int(size.height / bandHeight) + 1 {
            let y = CGFloat(index) * bandHeight + offset
            let color: Color = index.isMultiple(of: 3) ? palette.hotPink : (index.isMultiple(of: 2) ? palette.cyan : palette.acid)
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: bandHeight - 2)),
                         with: .color(color.opacity(0.5 + Double(rhythm.beatPulse) * 0.25)))
        }
    }

    private func drawCheckerboard(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let cells = 12
        let cell = max(size.width, size.height) / CGFloat(cells)
        let offset = CGFloat((time * 36).truncatingRemainder(dividingBy: Double(cell)))
        for row in -1...cells + 1 {
            for column in -1...cells + 1 where (row + column).isMultiple(of: 2) {
                let rect = CGRect(
                    x: CGFloat(column) * cell - offset,
                    y: CGFloat(row) * cell - offset,
                    width: cell + 1,
                    height: cell + 1)
                context.fill(Path(rect), with: .color(palette.hotPink.opacity(0.35)))
            }
        }
    }

    private func drawTurntable(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.34
        let disk = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: disk), with: .color(.black.opacity(0.8)))
        for ring in 1...5 {
            let r = radius * CGFloat(ring) / 5
            context.stroke(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)),
                           with: .color(palette.violet.opacity(0.6)), lineWidth: 1)
        }
        let angle = time * 4.2
        var arm = Path()
        arm.move(to: CGPoint(x: center.x + radius * 0.72, y: center.y - radius * 0.72))
        arm.addLine(to: CGPoint(
            x: center.x + CGFloat(Foundation.cos(angle)) * radius * 0.35,
            y: center.y + CGFloat(Foundation.sin(angle)) * radius * 0.35))
        strokeGlow(context: &context, path: arm, color: palette.amber)
    }

    private func drawRibbon(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        var ribbon = Path()
        let count = 96
        for index in 0..<count {
            let t = Double(index) / Double(count - 1)
            let x = size.width * CGFloat(t)
            let barsValue = bars.isEmpty ? 0.3 : Double(bars[index % bars.count])
            let y = size.height * 0.5
                + CGFloat(Foundation.sin(time * 3 + t * 18) * (30 + barsValue * 130))
            if index == 0 { ribbon.move(to: CGPoint(x: x, y: y)) }
            else { ribbon.addLine(to: CGPoint(x: x, y: y)) }
        }
        strokeGlow(context: &context, path: ribbon, color: palette.hotPink)
    }

    private func drawCubes(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for index in 0..<7 {
            let phase = time * 0.8 + Double(index)
            let side = min(size.width, size.height) * (0.08 + CGFloat(index) * 0.035)
            let x = center.x + CGFloat(Foundation.sin(phase * 1.3)) * size.width * 0.32
            let y = center.y + CGFloat(Foundation.cos(phase * 1.7)) * size.height * 0.26
            var cube = Path(roundedRect: CGRect(x: x-side, y: y-side, width: side*2, height: side*2), cornerRadius: 2)
            cube.move(to: CGPoint(x: x-side, y: y-side))
            cube.addLine(to: CGPoint(x: x-side*0.55, y: y-side*1.45))
            cube.addLine(to: CGPoint(x: x+side*1.45, y: y-side*1.45))
            cube.addLine(to: CGPoint(x: x+side, y: y-side))
            strokeGlow(context: &context, path: cube, color: index.isMultiple(of: 2) ? palette.acid : palette.cyan)
        }
    }

    private func drawAssetScene(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        asset: NSImage?,
        palette: KAOSPalette
    ) {
        _ = drawLineArt(
            context: &context,
            size: size,
            asset: asset,
            time: time,
            palette: palette,
            widthFraction: 0.62)
    }

    /// Draws supplied transparent line art over KAOS palette flares. The
    /// artwork stays recognisable while the surrounding beat rays/colors keep
    /// it part of the reactive scene instead of a static sticker.
    @discardableResult
    private func drawLineArt(
        context: inout GraphicsContext,
        size: CGSize,
        asset: NSImage?,
        time: TimeInterval,
        palette: KAOSPalette,
        widthFraction: CGFloat
    ) -> Bool {
        guard let asset else { return false }
        let aspect = max(0.1, asset.size.width / asset.size.height)
        let width = size.width * widthFraction * (1 + CGFloat(rhythm.beatPulse) * 0.08)
        let height = min(size.height * 0.74, width / aspect)
        let rect = CGRect(
            x: size.width / 2 - width / 2,
            y: size.height / 2 - height / 2,
            width: width,
            height: height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angle = Foundation.sin(time * 0.55) * 0.05
        var artContext = context
        artContext.translateBy(x: center.x, y: center.y)
        artContext.rotate(by: Angle(radians: angle))
        artContext.translateBy(x: -center.x, y: -center.y)

        let flare = Path(ellipseIn: rect.insetBy(dx: -width * 0.08, dy: -height * 0.12))
        context.fill(flare, with: .color(palette.hotPink.opacity(0.12 + Double(rhythm.beatPulse) * 0.2)))
        artContext.draw(Image(nsImage: asset), in: rect)
        if glow {
            var glowContext = artContext
            glowContext.addFilter(.blur(radius: 5))
            glowContext.draw(Image(nsImage: asset), in: rect)
        }
        return true
    }

    // MARK: - Shared layers

    private func drawSpectrum(
        context: inout GraphicsContext,
        size: CGSize,
        palette: KAOSPalette
    ) {
        guard !bars.isEmpty else { return }
        let count = min(48, bars.count)
        let width = size.width / CGFloat(count)
        for index in 0..<count {
            let value = min(1, CGFloat(bars[index]) * 1.7)
            let height = size.height * value * 0.28
            let rect = CGRect(
                x: CGFloat(index) * width,
                y: size.height - height,
                width: max(1, width - 1),
                height: height)
            context.fill(
                Path(rect),
                with: .color(index.isMultiple(of: 2) ? palette.hotPink.opacity(0.7) : palette.cyan.opacity(0.7)))
        }
    }

    private func drawTypography(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        sceneStep: Int,
        palette: KAOSPalette
    ) {
        let words = ["ACID", "HOUSE", "DANCE", "BASS", "JACK", "RAVE", "BEAT", "GROOVE", "KAOS"]
        let index = (sceneStep + rhythm.phraseIndex * 3 + rhythm.barPhase) % words.count
        // Kick/bass events own the typography for a short stuttering burst:
        // the word can flash several times during one beat decay, rather than
        // merely appearing as another scene-selected card.
        let activeVoices = rhythm.activeVoiceMask.nonzeroBitCount
        // Reserve text for recognizably sparse bass/drum passages: strong
        // low energy, subdued mids, and few active tonal voices (or digi
        // sample activity). Phrase starts can also introduce a rare card.
        let bassBreak = rhythm.beatConfidence > 0.48
            && rhythm.beatPulse > 0.9
            && rhythm.bassEnergy > max(0.24, rhythm.midEnergy * 1.9)
            && (activeVoices <= 2 || rhythm.digiActivity > 0.55)
        let phraseFlash = rhythm.phraseStartPulse > 0.9
            && rhythm.beatPulse > 0.8
        let strobeVisible = bassBreak || phraseFlash
        guard strobeVisible else { return }
        let word = bassBreak ? "BASS" : words[index]
        let widthFit = size.width / CGFloat(max(1, word.count)) * 1.12
        let heightFit = size.height * 0.44
        let fontSize = min(widthFit, heightFit) * (
            0.72 + CGFloat(rhythm.beatPulse) * (bassBreak ? 0.16 : 0.08))
        let digitalFont = Font.custom("Menlo-Bold", size: fontSize)
        let flashOpacity = pow(
            Double(rhythm.beatPulse),
            bassBreak ? 6.0 : 7.5)
        let point = CGPoint(
            x: size.width * 0.5 + CGFloat(sin(time * (bassBreak ? 10 : 2.7))) * 5,
            y: size.height * (0.5 + CGFloat(sin(time * 1.4)) * 0.012))
        let offset = 4 + CGFloat(rhythm.beatPulse) * (bassBreak ? 12 : 7)
        let shadow = Text(word).font(digitalFont).kerning(fontSize * 0.06)
        context.draw(
            shadow.foregroundColor(palette.hotPink.opacity(0.9 * flashOpacity)),
            at: CGPoint(x: point.x + offset, y: point.y + 3),
            anchor: .center)
        context.draw(
            shadow.foregroundColor(palette.cyan.opacity(0.85 * flashOpacity)),
            at: CGPoint(x: point.x - offset, y: point.y - 2),
            anchor: .center)
        context.draw(
            shadow.foregroundColor(.white.opacity(flashOpacity)),
            at: point,
            anchor: .center)
    }

    private func drawLissajousOrbit(
        context: inout GraphicsContext,
        size: CGSize,
        palette: KAOSPalette
    ) {
        guard lissajousPoints.count > 1 else { return }
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.53)
        let scale = min(size.width, size.height) * (
            0.19 + CGFloat(rhythm.beatPulse) * 0.08)
        var path = Path()
        for (index, point) in lissajousPoints.suffix(220).enumerated() {
            let x = center.x + CGFloat(point.left) * scale * 2.2
            let y = center.y - CGFloat(point.right) * scale * 2.2
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        strokeGlow(context: &context, path: path, color: palette.amber)
    }

    private func drawBeatRays(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        palette: KAOSPalette
    ) {
        guard rhythm.beatPulse > 0.18 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let length = hypot(size.width, size.height)
            * CGFloat(rhythm.beatPulse) * 0.7
        var rays = Path()
        for index in 0..<20 {
            let angle = time * 0.4 + Double(index) * .pi * 2 / 20
            rays.move(to: center)
            rays.addLine(to: CGPoint(
                x: center.x + CGFloat(Foundation.cos(angle)) * length,
                y: center.y + CGFloat(Foundation.sin(angle)) * length))
        }
        context.stroke(
            rays,
            with: .color(palette.hotPink.opacity(Double(rhythm.beatPulse) * 0.32)),
            lineWidth: 1)
    }

    private func drawBeatFlash(
        context: inout GraphicsContext,
        size: CGSize,
        palette: KAOSPalette
    ) {
        guard rhythm.beatPulse > 0.72 else { return }
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(palette.acid.opacity(Double(rhythm.beatPulse - 0.72) * 0.25)))
    }

    private func drawScanlines(context: inout GraphicsContext, size: CGSize) {
        var lines = Path()
        for y in stride(from: CGFloat(0), through: size.height, by: 4) {
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lines, with: .color(.black.opacity(0.28)), lineWidth: 1)
    }

    private func strokeGlow(
        context: inout GraphicsContext,
        path: Path,
        color: Color
    ) {
        if glow {
            var glowContext = context
            glowContext.addFilter(.blur(radius: 5))
            glowContext.stroke(path, with: .color(color.opacity(0.32)), lineWidth: 3)
        }
        context.stroke(path, with: .color(color), lineWidth: 1.25)
    }
}
