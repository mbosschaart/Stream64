import Foundation
import CoreGraphics

/// One SID Oscilloscope window's saved state — which visualization mode it
/// was showing and where it was positioned/sized on screen.
struct SIDWindowLayoutEntry: Codable, Equatable {
    var mode: String
    var frame: CGRect
}

/// A saved arrangement of every SID Oscilloscope window open for one
/// device at the moment it was saved. "Open All in Grid" is a good
/// starting point, but users often nudge/resize/close individual windows
/// afterward to their own taste — this lets that arrangement be restored
/// later, even after quitting and relaunching the app, instead of
/// re-arranging everything by hand each time.
struct SIDWindowLayoutSnapshot: Codable, Equatable {
    var entries: [SIDWindowLayoutEntry]
    var savedAt: Date
}

/// Per-device persistence for `SIDWindowLayoutSnapshot`, following the same
/// UserDefaults JSON-blob pattern as `DisplaySettings`/`InputSettings`.
enum SIDWindowLayoutStore {
    private static func storageKey(for deviceID: UUID) -> String {
        "sidWindowLayout.\(deviceID.uuidString)"
    }

    /// Persists `snapshot` for `deviceID`, replacing any layout already
    /// stored under the same key.
    static func save(_ snapshot: SIDWindowLayoutSnapshot, for deviceID: UUID) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(for: deviceID))
    }

    static func load(for deviceID: UUID) -> SIDWindowLayoutSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: deviceID)),
              let snapshot = try? JSONDecoder().decode(SIDWindowLayoutSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    static func hasSavedLayout(for deviceID: UUID) -> Bool {
        !(load(for: deviceID)?.entries.isEmpty ?? true)
    }

    static func clear(for deviceID: UUID) {
        UserDefaults.standard.removeObject(forKey: storageKey(for: deviceID))
    }
}
