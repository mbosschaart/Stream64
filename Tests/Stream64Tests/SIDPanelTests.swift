import XCTest
import SwiftUI
import AppKit
@testable import Stream64

final class SIDPanelTests: XCTestCase {
    func testRepeatedWritesStayVisibleWithoutRetriggeringChangeFlash() {
        var activity = SIDRegisterActivity(chipCount: 2)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        activity.record(chipIndex: 1, offset: 24, value: 15, at: start)
        for frame in 1...50 {
            activity.record(chipIndex: 1, offset: 24, value: 15,
                            at: start.addingTimeInterval(Double(frame) / 50))
        }
        let now = start.addingTimeInterval(1)
        XCTAssertEqual(activity.values[1][24], 15)
        XCTAssertEqual(activity.intensity(chipIndex: 1, offset: 24, at: now, changes: false), 1)
        XCTAssertEqual(activity.intensity(chipIndex: 1, offset: 24, at: now, changes: true), 0)
        XCTAssertNil(activity.values[0][24])
        activity.record(chipIndex: 1, offset: 24, value: 14, at: now)
        XCTAssertEqual(activity.intensity(chipIndex: 1, offset: 24, at: now, changes: true), 1)
        XCTAssertEqual(activity.intensity(chipIndex: 1, offset: 24,
            at: now.addingTimeInterval(0.3), changes: true), 0)
        XCTAssertEqual(activity.intensity(chipIndex: 1, offset: 24,
            at: now.addingTimeInterval(0.3), changes: false), 0)
    }

    func testChangeWithinOneEngineTickIsNotLostWhenValueReturns() {
        var activity = SIDRegisterActivity(chipCount: 1)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        activity.record(chipIndex: 0, offset: 4, value: 0x41, at: start)
        let tick = start.addingTimeInterval(1)
        activity.record(chipIndex: 0, offset: 4, value: 0x40, at: tick)
        activity.record(chipIndex: 0, offset: 4, value: 0x41, at: tick)
        activity.record(chipIndex: 0, offset: 4, value: 0x41, at: tick)
        XCTAssertEqual(activity.values[0][4], 0x41)
        XCTAssertEqual(activity.lastChange[0][4], tick)
        XCTAssertEqual(activity.intensity(chipIndex: 0, offset: 4, at: tick, changes: true), 1)
    }

    func testFullscreenTypographyScalesWithoutDoubleScalingResponsiveViews() {
        let modes: [SIDVisualizationMode] = [.oscilloscope, .envelope, .mixerConsole,
            .pianoRoll, .pianoKeyboard, .voiceLineup, .filterCurve, .spectrogram,
            .vuMeterBank, .adsrKnobs, .pulseWidth]
        for chips in [1, 2] {
            for mode in modes {
                let compact = SIDVisualizationScale.factor(mode: mode, chipCount: chips,
                    size: CGSize(width: 760, height: 460))
                let fullscreen = SIDVisualizationScale.factor(mode: mode, chipCount: chips,
                    size: CGSize(width: 1920, height: 1080))
                let large = SIDVisualizationScale.factor(mode: mode, chipCount: chips,
                    size: CGSize(width: 3840, height: 2160))
                XCTAssertEqual(compact, 1)
                XCTAssertGreaterThan(fullscreen, 1.5, mode.displayName)
                XCTAssertEqual(large, fullscreen * 2, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(1920 / fullscreen, 900)
                XCTAssertGreaterThanOrEqual(1080 / fullscreen, chips == 2 ? 600 : 400)
            }
        }
        for mode in [SIDVisualizationMode.kaos, .registerActivity, .controlBits, .dashboard, .alienFlower] {
            XCTAssertEqual(SIDVisualizationScale.factor(mode: mode, chipCount: 1,
                size: CGSize(width: 1920, height: 1080)), 1)
        }
    }

    func testPianoKeyProportionsStayFixedAndFitBothAxes() {
        for size in [CGSize(width: 300, height: 900), CGSize(width: 1900, height: 250),
                     CGSize(width: 900, height: 70), CGSize(width: 80, height: 20)] {
            let rect = SIDPianoKeyboardLayout.keyboardRect(in: size)
            let keyWidth = rect.width / CGFloat(SIDPianoKeyboardLayout.whiteKeys().count)
            XCTAssertEqual(rect.height / keyWidth, 5.5, accuracy: 0.001)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
            XCTAssertEqual(rect.midX, size.width / 2, accuracy: 0.001)
            XCTAssertEqual(rect.midY, size.height / 2, accuracy: 0.001)
        }
    }

    @MainActor
    func testPanelsRenderAtWindowAndFullscreenSizes() throws {
        for chips in [1, 2] {
            var activity = SIDRegisterActivity(chipCount: chips)
            let channels: [SIDVoiceChannel] = (0..<chips*3).map { index in
                var voice = SIDVoiceChannel(id: index, chipIndex: index / 3,
                    voiceIndex: index % 3, bufferSize: 8, noteHistoryLength: 6)
                voice.registers.control = 0x41
                voice.registers.frequency = 14000
                voice.registers.attackDecay = 0x58
                voice.registers.sustainRelease = 0xA6
                return voice
            }
            for chip in 0..<chips {
                for offset in 0..<25 {
                    activity.record(chipIndex: chip, offset: offset, value: UInt8(offset), at: Date())
                }
            }
            let filters = Array(repeating: SIDFilterRegisters(modeVolume: 0x7f), count: chips)
            for size in [CGSize(width: 900, height: 500), CGSize(width: 1920, height: 1080),
                         CGSize(width: 640, height: 700)] {
                let scenes: [(String, AnyView)] = [
                    ("Registers", AnyView(SIDRegisterActivityView(activity: activity))),
                    ("Control", AnyView(SIDChannelGrid(channels: channels, chipCount: chips) {
                        SIDControlBitsPanel(channel: $0)
                    })),
                    ("Dashboard", AnyView(SIDDashboardView(channels: channels, filterStates: filters)))
                ]
                let legacy: [(SIDVisualizationMode, AnyView)] = [
                    (.oscilloscope, AnyView(SIDChannelGrid(channels: channels, chipCount: chips) {
                        SIDChannelPanel(channel: $0, glow: false)
                    })),
                    (.envelope, AnyView(SIDChannelGrid(channels: channels, chipCount: chips) {
                        SIDEnvelopePanel(channel: $0, glow: false)
                    })),
                    (.mixerConsole, AnyView(SIDChannelGrid(channels: channels, chipCount: chips) {
                        SIDMixerStripPanel(channel: $0)
                    })),
                    (.pianoRoll, AnyView(SIDPianoRollView(channels: channels))),
                    (.pianoKeyboard, AnyView(SIDPianoKeyboardView(channels: channels))),
                    (.voiceLineup, AnyView(SIDVoiceLineupView(channels: channels))),
                    (.filterCurve, AnyView(SIDFilterCurveView(channels: channels, filterStates: filters))),
                    (.spectrogram, AnyView(SIDSpectrogramView(history: []))),
                    (.vuMeterBank, AnyView(SIDVUMeterBankView(channels: channels))),
                    (.adsrKnobs, AnyView(SIDChannelGrid(channels: channels, chipCount: chips) {
                        SIDADSRKnobPanel(channel: $0)
                    })),
                    (.pulseWidth, AnyView(SIDChannelGrid(channels: channels, chipCount: chips) {
                        SIDPulseWidthPanel(channel: $0)
                    })),
                    (.oscilloscope, AnyView(SIDPostMixKickScope(chipIndex: 0,
                        samples: [], bassLevel: 0.5, glow: false)))
                ]
                let scaled = legacy.enumerated().map { index, entry in
                    ("\(entry.0.displayName)-\(index)", AnyView(SIDVisualizationSizing(mode: entry.0, chipCount: chips) {
                        entry.1
                    }))
                }
                for (name, scene) in scenes + scaled {
                    let content = scene.frame(width: size.width, height: size.height)
                    let image: NSImage
                    if name.hasPrefix("Spectrogram") {
                        // ImageRenderer substitutes a warning symbol for NSViewRepresentable.
                        // Exercise the actual AppKit heatmap and SwiftUI gutter together.
                        let host = NSHostingView(rootView: content)
                        host.frame = CGRect(origin: .zero, size: size)
                        host.layoutSubtreeIfNeeded()
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        image = NSImage(size: size)
                        image.addRepresentation(bitmap)
                    } else {
                        let renderer = ImageRenderer(content: content)
                        renderer.scale = 1
                        image = try XCTUnwrap(renderer.nsImage, name)
                    }
                    XCTAssertEqual(image.size, size)
                    if let directory = ProcessInfo.processInfo.environment["STREAM64_PANEL_PREVIEWS"] {
                        let url = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                            url.appendingPathComponent("\(name)-\(chips)-\(Int(size.width)).png"))
                    }
                }
            }
        }
    }
}
