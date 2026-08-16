import SwiftUI

/// Caches one live DeviceSession per device. Held in @StateObject so the
/// cache survives both body re-evaluation AND recreation of the view struct
/// (which happens whenever any observed object publishes) — a plain `let`
/// property would silently start a second session per device, splitting the
/// UI and the streams across different session objects.
@MainActor
final class SessionManager: ObservableObject {
    private var sessions: [UUID: DeviceSession] = [:]
    private var audibleID: UUID?
    let airPlayOutput = AirPlayOutputController()

    init() {
        airPlayOutput.onExternalPlaybackChanged = { [weak self] active in
            self?.applyExternalOutputSuppression(active)
        }
    }

    func session(for device: UltimateDevice, settings: AppSettings) -> DeviceSession {
        if let existing = sessions[device.id], existing.device == device {
            return existing
        }
        if let existing = sessions.removeValue(forKey: device.id) {
            // Defensive fallback for an update that bypassed the normal
            // async edit flow: release local ports immediately, but do not
            // issue delayed remote stop commands that could kill the new
            // session's streams.
            existing.prepareForEviction()
            Task {
                await existing.disconnect(stopRemoteStreams: false)
            }
        }
        let session = DeviceSession(device: device, settings: settings)
        sessions[device.id] = session
        session.audioReceiver.muted = device.id != audibleID
        session.audioReceiver.externalOutputSuppressed =
            airPlayOutput.externalOutputActive && device.id == audibleID
        if device.id == audibleID {
            airPlayOutput.setSource(session.audioReceiver)
        }
        return session
    }

    /// Complete remote shutdown before removing the cache entry. The device
    /// remains visible while this awaits, preventing remove/re-add or edit
    /// from creating a replacement whose newly-started streams are then
    /// stopped by the old session's delayed cleanup.
    func removeSession(
        id: UUID,
        clearAudibleSelection: Bool = true
    ) async {
        guard let session = sessions[id] else { return }
        session.prepareForEviction()
        await session.disconnect(stopRemoteStreams: true) { [weak self] in
            self?.sessions[id] === session
        }
        guard sessions[id] === session else { return }
        sessions.removeValue(forKey: id)
        if clearAudibleSelection, audibleID == id {
            audibleID = nil
            airPlayOutput.setSource(nil)
        }
    }

    var cachedSessionCount: Int { sessions.count }
    func hasCachedSession(id: UUID) -> Bool { sessions[id] != nil }

    /// Audio policy: exactly one device is audible — the one on screen (or
    /// selected, in the grid). Background sessions keep streaming muted.
    func muteAll(except audibleID: UUID?) {
        self.audibleID = audibleID
        for (id, session) in sessions {
            session.audioReceiver.muted = id != audibleID
            session.audioReceiver.externalOutputSuppressed =
                airPlayOutput.externalOutputActive && id == audibleID
        }
        airPlayOutput.setSource(
            audibleID.flatMap { sessions[$0]?.audioReceiver })
    }

    private func applyExternalOutputSuppression(_ active: Bool) {
        for (id, session) in sessions {
            session.audioReceiver.externalOutputSuppressed =
                active && id == audibleID
        }
    }

    func applyGlobalVolume(_ volume: Float) {
        for session in sessions.values {
            session.audioReceiver.volume = volume
        }
    }

    func applyAudioOutputDeviceUID(_ uid: String) {
        for session in sessions.values {
            session.audioReceiver.preferredOutputDeviceUID = uid
        }
    }

    func applyDebugStreamWarmPreference() {
        for session in sessions.values {
            session.updateDebugStreamWarmPreference()
        }
    }

    /// Immediate local teardown for app quit — stops AirPlay and every
    /// receiver/engine before any remote REST work, so music cannot keep
    /// playing while `disconnect` awaits an unreachable Ultimate.
    func prepareForAppTermination() {
        airPlayOutput.stopAirPlay()
        audibleID = nil
        for session in sessions.values {
            session.prepareForEviction()
        }
    }

    func disconnectAll() async {
        airPlayOutput.stopAirPlay()
        audibleID = nil
        let currentSessions = Array(sessions.values)
        // Evict and stop remotes while these sessions still own the cache
        // slots — clearing first would let a replacement claim the device
        // and then get its streams killed by the old stop calls.
        for session in currentSessions {
            session.prepareForEviction()
        }
        for session in currentSessions {
            let id = session.device.id
            await session.disconnect(
                stopRemoteStreams: true,
                waitForInputRelease: false
            ) { [weak self] in
                self?.sessions[id] === session
            }
        }
        sessions.removeAll()
    }

    /// Multi Drop: load a file on every connected session at once.
    func loadFileOnAllConnected(_ url: URL) {
        for session in sessions.values where session.isConnected {
            Task { await session.loadFile(at: url) }
        }
    }
}
