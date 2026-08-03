import Foundation
import AVFoundation
import AVKit

private final class AirPlayEncoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LiveAirPlayEncoder?

    func get() -> LiveAirPlayEncoder? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: LiveAirPlayEncoder?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

/// One app-wide AirPlay route. macOS AVRoutePickerView publicly routes an
/// AVPlayer only, so this player consumes Stream64's temporary live HLS URL.
@MainActor
final class AirPlayOutputController: NSObject, ObservableObject {
    enum RouteState: Equatable {
        case local
        case preparing
        case connecting
        case airPlay
        case failed(String)

        var label: String {
            switch self {
            case .local: return "This Mac"
            case .preparing: return "Preparing AirPlay…"
            case .connecting: return "Connecting…"
            case .airPlay: return "AirPlay"
            case .failed: return "AirPlay Failed"
            }
        }
    }

    let player = AVPlayer()
    @Published private(set) var state: RouteState = .local
    @Published private(set) var externalOutputActive = false
    /// Once a receiver has activated, output remains globally locked to
    /// AirPlay until the user explicitly calls `stopAirPlay()`. C64/session
    /// lifecycle changes are source changes, never route-policy changes.
    @Published private(set) var isAirPlayLocked = false

    var onExternalPlaybackChanged: ((Bool) -> Void)?

    private weak var selectedReceiver: AudioReceiver?
    private var selectedObserverID: UUID?
    private var server: LiveHLSServer?
    private var encoder: LiveAirPlayEncoder?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var pickerGeneration = 0
    private var routeLossGeneration = 0
    private var hasActivatedAirPlay = false
    private let encoderBox = AirPlayEncoderBox()
    /// AVRoutePickerView participates in macOS route ownership. SwiftUI can
    /// recreate toolbar/settings representables during ordinary interaction;
    /// retaining stable picker instances here prevents that lifecycle churn
    /// from tearing down the selected AirPlay route.
    private var retainedRoutePickers: [String: AVRoutePickerView] = [:]

    override init() {
        super.init()
        player.allowsExternalPlayback = true
        player.isMuted = true
        player.volume = 0
        externalPlaybackObservation = player.observe(
            \.isExternalPlaybackActive,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor in
                self?.externalPlaybackDidChange(
                    active: player.isExternalPlaybackActive)
            }
        }
    }

    deinit {
        if let selectedObserverID {
            selectedReceiver?.removeSampleObserver(selectedObserverID)
        }
    }

    func setSource(_ receiver: AudioReceiver?) {
        // SwiftUI view-mode/focus changes can reapply the global audio policy
        // without changing the selected C64. Reattaching the same observer
        // inserted an unnecessary HLS discontinuity and could make AirPlay
        // temporarily drop back to local playback.
        if let receiver,
           receiver === selectedReceiver,
           selectedObserverID != nil {
            return
        }
        if receiver == nil, selectedReceiver == nil {
            if state != .local {
                stopPipeline(restoreLocal: true)
            }
            return
        }
        if let selectedObserverID {
            selectedReceiver?.removeSampleObserver(selectedObserverID)
        }
        selectedObserverID = nil
        selectedReceiver = receiver

        guard let receiver else {
            // Keep a locked AirPlay route alive with encoder-generated
            // silence while no C64 is selected or a session reconnects.
            return
        }
        selectedObserverID = receiver.addSampleObserver {
            [weak self, weak receiver] samples in
            guard let self else { return }
            let gain = receiver?.volume ?? 1
            self.currentEncoder()?.enqueue(
                samples: samples,
                gain: gain,
                rfEnabled: receiver?.rfAudioEnabled ?? false)
        }
    }

    /// Called just before AVRoutePickerView presents destinations. Preparing
    /// muted live playback gives its player a routable item without producing
    /// duplicate local audio while the popover is open.
    func prepareForRouteSelection() {
        pickerGeneration += 1
        guard server == nil else {
            if state == .local { state = .connecting }
            return
        }
        state = .preparing

        let server = LiveHLSServer()
        self.server = server
        server.start { [weak self, weak server] result in
            Task { @MainActor in
                guard let self, self.server === server else { return }
                switch result {
                case .success(let url):
                    self.startEncoderAndPlayer(url: url, server: server!)
                case .failure(let error):
                    self.fail(error)
                }
            }
        }
    }

    func routePickerDidClose() {
        guard !isAirPlayLocked else { return }
        let generation = pickerGeneration
        Task { @MainActor [weak self] in
            // Route negotiation can outlive the picker popover by several
            // seconds while the receiver buffers the live HLS edge.
            try? await Task.sleep(for: .seconds(15))
            guard let self,
                  generation == self.pickerGeneration,
                  !self.player.isExternalPlaybackActive else { return }
            self.stopPipeline(restoreLocal: true)
        }
    }

    func stopAirPlay() {
        pickerGeneration += 1
        isAirPlayLocked = false
        stopPipeline(restoreLocal: true)
    }

    func routePicker(
        identifier: String,
        delegate: AVRoutePickerViewDelegate
    ) -> AVRoutePickerView {
        if let existing = retainedRoutePickers[identifier] {
            existing.player = player
            existing.delegate = delegate
            return existing
        }
        let picker = AVRoutePickerView(frame: .zero)
        picker.player = player
        picker.delegate = delegate
        picker.isRoutePickerButtonBordered = false
        retainedRoutePickers[identifier] = picker
        return picker
    }

    private func startEncoderAndPlayer(
        url: URL,
        server: LiveHLSServer
    ) {
        do {
            let encoder = LiveAirPlayEncoder(server: server)
            encoder.onFailure = { [weak self] error in
                Task { @MainActor in self?.fail(error) }
            }
            try encoder.start()
            setCurrentEncoder(encoder)
            self.encoder = encoder
            state = .preparing
            startPlayerWhenPlaylistIsReady(
                url: url,
                server: server,
                generation: pickerGeneration)
        } catch {
            fail(error)
        }
    }

    private func startPlayerWhenPlaylistIsReady(
        url: URL,
        server: LiveHLSServer,
        generation: Int
    ) {
        Task { @MainActor [weak self, weak server] in
            for _ in 0..<80 {
                guard let self,
                      let server,
                      self.server === server,
                      self.pickerGeneration == generation else { return }
                if server.hasInitializationSegment,
                   server.mediaSegmentCount > 0 {
                    self.startPlayer(url: url)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.fail(LiveHLSServer.ServerError.failed(
                "No live audio reached the AirPlay encoder."))
        }
    }

    private func startPlayer(url: URL) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1.5
        itemStatusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                self?.fail(
                    item.error ?? LiveHLSServer.ServerError.failed(
                        "AVPlayer item failed."))
            }
        }
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.volume = 0
        player.play()
        state = .connecting
    }

    private func externalPlaybackDidChange(active: Bool) {
        if active {
            routeLossGeneration += 1
            hasActivatedAirPlay = true
            isAirPlayLocked = true
            player.volume = 1
            player.isMuted = false
            state = .airPlay
            setExternalOutputActive(true)
        } else if hasActivatedAirPlay {
            // AVPlayer can briefly report false while the live edge
            // rebuffers or the selected Stream64 view is reconstructed.
            // Keep local output suppressed during a grace period rather
            // than audibly jumping back to the Mac.
            // Stop before AVPlayer can render the formerly-external item
            // through this Mac. Both mute and volume are set because route
            // transitions have proven capable of briefly ignoring one.
            player.pause()
            player.isMuted = true
            player.volume = 0
            state = .connecting
            // Reapply even if our state already says active: SwiftUI view
            // reconstruction/session policy may have touched a receiver gate.
            onExternalPlaybackChanged?(true)
            routeLossGeneration += 1
            let generation = routeLossGeneration
            retryLockedRoute(generation: generation)
        }
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        if isAirPlayLocked {
            // Never change output policy because a live transport component
            // failed. Keep local suppressed and rebuild the same app-wide
            // AirPlay player pipeline.
            stopPipeline(restoreLocal: false)
            state = .connecting
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isAirPlayLocked else { return }
                self.prepareForRouteSelection()
            }
        } else {
            stopPipeline(restoreLocal: true)
            state = .failed(message)
        }
    }

    private func stopPipeline(restoreLocal: Bool) {
        player.isMuted = true
        player.volume = 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        setCurrentEncoder(nil)
        encoder?.stop()
        encoder = nil
        server?.stop()
        server = nil
        routeLossGeneration += 1
        hasActivatedAirPlay = false
        if restoreLocal {
            setExternalOutputActive(false)
            if case .failed = state {
                // Preserve the useful error state until the next attempt.
            } else {
                state = .local
            }
        }
    }

    nonisolated private func currentEncoder() -> LiveAirPlayEncoder? {
        encoderBox.get()
    }

    private func setCurrentEncoder(_ encoder: LiveAirPlayEncoder?) {
        encoderBox.set(encoder)
    }

    private func setExternalOutputActive(_ active: Bool) {
        guard externalOutputActive != active else { return }
        externalOutputActive = active
        onExternalPlaybackChanged?(active)
    }

    private func retryLockedRoute(generation: Int) {
        Task { @MainActor [weak self] in
            while let self,
                  self.isAirPlayLocked,
                  generation == self.routeLossGeneration,
                  !self.player.isExternalPlaybackActive {
                try? await Task.sleep(for: .milliseconds(500))
                guard self.isAirPlayLocked,
                      generation == self.routeLossGeneration else { return }
                // The AVPlayer retains the destination selected by Apple's
                // picker. Keep retrying that route muted; only an external
                // activation callback restores player volume.
                self.player.isMuted = true
                self.player.volume = 0
                self.player.play()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
