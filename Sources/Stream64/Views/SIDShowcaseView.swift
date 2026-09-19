import AppKit
import SwiftUI

/// A six-object SID stage: all artwork stays visible, while voice ownership
/// and the distortion treatment rotate. Uses only shared-engine refreshes.
struct SIDShowcaseView: View {
    let channels: [SIDVoiceChannel]
    let filters: [SIDFilterRegisters]
    let rhythm: KAOSRhythmState
    var glow = false
    var underPressure = false

    var body: some View {
        SIDPerformanceGPUView(scene: .showcase,
            input: .snapshot(mode: .sidShowcase, channels: channels, filters: filters, rhythm: rhythm, glow: glow),
            channels: channels, underPressure: underPressure)
    }
}

enum SIDShowcaseLayout {
    static let names = ["COMPUTER", "FLOPPY DRIVE", "TAPE", "DISK", "JOYSTICK", "1702 MONITOR"]
    static let resources = ["kaos-c64", "kaos-1541", "kaos-cassette", "kaos-floppy", "kaos-joystick", "showcase-1702"]
    static let assignmentInterval: TimeInterval = 4

    static func voice(for image: Int, count: Int, time: TimeInterval) -> Int {
        let turn = Int(max(0, time) / assignmentInterval)
        return (image + turn) % max(1, count)
    }

    static func slot(for image: Int, size: CGSize) -> CGRect {
        let portrait = size.width < size.height
        let centers: [CGPoint] = portrait
            ? [.init(x: 0.25, y: 0.18), .init(x: 0.75, y: 0.18),
               .init(x: 0.25, y: 0.48), .init(x: 0.75, y: 0.48),
               .init(x: 0.25, y: 0.78), .init(x: 0.75, y: 0.78)]
            : [.init(x: 0.5, y: 0.26), .init(x: 0.18, y: 0.26), .init(x: 0.82, y: 0.26),
               .init(x: 0.18, y: 0.73), .init(x: 0.82, y: 0.73), .init(x: 0.5, y: 0.73)]
        let width = size.width * (portrait ? 0.38 : 0.25)
        let height = size.height * (portrait ? 0.23 : 0.32)
        let center = centers[image]
        return CGRect(x: center.x * size.width - width / 2,
                      y: center.y * size.height - height / 2, width: width, height: height)
    }

    static let images: [NSImage?] = resources.map { name in
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? (ResourceBundle.isPackagedApp ? nil : Bundle.module.url(forResource: name, withExtension: "png"))
        return url.flatMap { NSImage(contentsOf: $0) }
    }
}
