# Stream64 — Developer Handover Document

**Project:** Stream64  
**GitHub:** https://github.com/mbosschaart/Stream64  
**Local path:** `~/UltimateViewer`  
**Author:** Martijn Bosschaart, 2026  
**Last updated:** 2026-07-20

This document is the primary reference for a developer picking up Stream64 cold. It covers every design decision, every non-obvious constraint, and everything discovered the hard way. Read it before touching anything.

---

## 1. Project Overview

Stream64 is a native macOS viewer and remote control for the **Commodore 64 Ultimate** family of devices (Ultimate 64, Ultimate 64 Elite, Ultimate-II+). These are FPGA-based recreations of the original Commodore 64 hardware that can stream their VIC video output and SID audio output over a local network as UDP packets.

The app:
- Receives the live video stream (384×272 pixels at ~50 fps PAL) and audio (47983 Hz stereo) over UDP
- Renders the picture via Metal with four filter pipelines including authentic CRT tube simulation
- Simulates signal-path degradation: S-Video (clean), Composite (chroma bleed, dot crawl), RF (snow, jitter, interference, TV-speaker audio)
- Wraps the picture in period-correct Commodore 1702 or 1084S monitor bezels drawn in SwiftUI, with working front-panel knobs on the 1702
- Injects keyboard input into the C64's KERNAL buffer over DMA (the only mechanism available)
- Provides machine control: reset, reboot, pause/resume, menu button, power off
- Supports drag-and-drop loading of PRGs and disk images (`.d64/.g64/.d71/.g71/.d81`)
- Integrates with the Assembly64 online software library for in-app browsing and loading
- Handles multiple devices simultaneously in a grid view, each with independent rendering settings

**Target platform:** macOS 14 (Sonoma) or newer, arm64 and x86_64 with Metal-capable GPU.
**Required device firmware:** Ultimate 64/Elite 3.11+, or C64 Ultimate 1.1+. Tested against legacy 3.14 and C64 Ultimate 1.1.0.
**Build system:** Swift Package Manager (`swift run` or open folder in Xcode).

---

## 2. Architecture

```
┌──────────────┐  REST (HTTP)   ┌───────────────────┐
│              │◀──────────────▶│ UltimateAPIClient │  control plane
│  C64 Ultimate│                └───────────────────┘
│   (device)   │  UDP video     ┌───────────────────┐   ┌────────────────────┐
│              │───────────────▶│  VideoReceiver    │──▶│ MetalFrameRenderer │──▶ screen
│              │  UDP audio     ├───────────────────┤   └────────────────────┘
│              │───────────────▶│  AudioReceiver    │──▶ AVAudioEngine ──▶ speakers
└──────────────┘                └───────────────────┘
                                        ▲
                               DeviceSession (per device)
                                        ▲
                     SessionManager (app-level @StateObject)
                                        ▲
                       SwiftUI views / DisplaySettings
```

### Layered component model

```
Stream64App
  ├── DeviceStore          (@StateObject, app-level) — persists device list
  ├── AppSettings          (@StateObject, app-level) — global prefs via @AppStorage
  ├── SessionManager       (@StateObject, app-level) — cache of live DeviceSessions
  │
  └── ContentView
        ├── DeviceSidebar
        ├── ViewerPane (single device)
        │     ├── MonitorBezelView (optional)
        │     │     └── VideoView (NSViewRepresentable → KeyCapturingMTKView)
        │     │               └── MetalFrameRenderer (MTKViewDelegate)
        │     └── OnScreenKeyboardView
        └── MultiViewerGrid (all devices)
              └── ViewerTile (per device)
                    └── VideoView (as above)

Per device (in DeviceSession):
  ├── VideoReceiver    — UDP listener, packet assembly, onFrame callback
  ├── AudioReceiver    — UDP listener, ring buffer, AVAudioSourceNode pull render
  ├── UltimateAPIClient — REST client
  └── DisplaySettings  — per-device rendering prefs (singleton by UUID)
```

### Data flow summary

1. User selects a device → `ViewerPane.task` calls `session.connect()`
2. `connect()` probes the device REST API (2 quick attempts), opens UDP listeners, polls for already-arriving packets (up to 600 ms), calls `startStreaming()` for any stream not yet live
3. Device sends UDP video packets → `VideoReceiver.handlePacket()` assembles 4bpp lines → `onFrame` callback → `MetalFrameRenderer.submitFrame()` stores in `pendingFrame`
4. `MTKView` display link calls `draw()` at 60 fps → renderer uploads `pendingFrame` to the next ring texture, sets uniforms, encodes draw call → screen
5. Device sends UDP audio packets → `AudioReceiver.handlePacket()` converts Int16→Float, writes to ring buffer; `AVAudioSourceNode` render callback pulls from ring buffer → speakers
6. User types → `KeyCapturingMTKView.keyDown()` → PETSCII encode → `DeviceSession.sendKeys()` → enqueued, drained by single worker → `UltimateAPIClient.typeKeys()` → DMA writes to $0277/$C6

---

## 3. Source File Inventory

Application source lives under `Sources/Stream64/`; XCTest coverage is under `Tests/Stream64Tests`, packaging metadata/scripts under `Packaging/` and `Scripts/`.

### `Stream64App.swift`
App entry point. Defines `Stream64App` (`@main`) and `AppDelegate`.

Key responsibilities:
- Creates the app-level `@StateObject`s: `DeviceStore`, `AppSettings`, `SessionManager`, and `Assembly64LibraryStore`
- Declares the `WindowGroup` (main viewer), `Window("help")`, `Window("assembly64")`, and `Settings` scenes
- `AppDelegate.applicationWillFinishLaunching` acquires `SingleInstanceLock`; a second launch activates the existing process and exits before creating competing UDP listeners
- `AppDelegate.applicationDidFinishLaunching` installs a `NSWindow.willCloseNotification` observer that calls `NSApp.terminate()` when the main viewer window closes — needed because an open Settings window otherwise keeps the process alive after the user "quit"
- Root `ContentView.onDisappear` is the authoritative SwiftUI fallback: `WindowGroup` may remove its `NSWindow` before `willClose` can classify it. The fallback calls terminate; `applicationShouldTerminate` immediately orders out/closes every Assembly64, Help, Settings and extra viewer window before returning `.terminateNow`.
- `isMainWindow()` identifies the main window by exclusion (Settings/help/assembly64 window IDs and panels are excluded), not by title, because the title changes to show the device name
- Menu commands: Add Device (⇧⌘N), Search Assembly64 (⇧⌘F), Stream64 Help (⌘?)
- `NSApplication.shared.setActivationPolicy(.regular)` in `init()` — required when launched via `swift run` (no app bundle), otherwise the process has no dock icon or menu bar

### `Models/UltimateDevice.swift`
Plain `struct UltimateDevice: Identifiable, Codable, Hashable`.

Fields: `id` (UUID), `name`, `host`, `apiPort` (default 80), `password`, `videoPort` (default 11000), `audioPort` (default 11001), `autoConnect`, `notes`.

Key computed properties:
- `baseURL` — constructs `http://host[:port]`, omits port when it is 80
- `displayAddress` — host or host:port string for UI labels
- `makeDefault(avoiding:)` — allocates the next available even-numbered port pair starting from 11000, walking by 2 until a pair not used by any existing device is found

### `Models/DeviceStore.swift`
`@MainActor final class DeviceStore: ObservableObject`

Persists the device list as JSON at `~/Library/Application Support/Stream64/devices.json`. The `storeURL` static property also checks for a legacy path under `UltimateViewer/` and copies it on first run — the app was originally named UltimateViewer.

`selectedDeviceID` is persisted in `UserDefaults` with key `"selectedDeviceID"`. On init, if the saved ID exists in the device list it is restored; otherwise defaults to the first device.

Mutating operations (`add`, `update`, `remove`) all trigger `didSet { save() }` on `devices`.

### `Models/AppSettings.swift`
`@MainActor final class AppSettings: ObservableObject`

Global preferences backed by `@AppStorage` (UserDefaults):
- Audio: `audioEnabled`, `volume` (0–1, default 0.8), `audioBufferMs` (default 60)
- Network: `connectTimeoutSeconds` (default 5), `streamDurationSeconds` (default 0 = forever)
- General: `reconnectAutomatically`, `captureKeyboardWhenFocused`, `confirmDestructiveActions`

Also defines `PictureControls` — a plain `final class` (not ObservableObject) with four Float fields: `brightness`, `contrast`, `saturation`, `tint`, all 0–1, neutral 0.5. This class is the bypass path for knob drags: the renderer reads it every frame without going through SwiftUI observation. See section 6 for the full story.

Also defines the enums used throughout the app:
- `ScalingMode`: integer, aspectFit, fill
- `FilterMode`: sharp, smooth, crt, crtTube
- `TubeInput`: svideo, composite, rf (with `signalLevel: Float` returning 0/1/2)
- `CRTScreenColor`: color, amber, green, blackAndWhite (with `shaderValue` 0/1/2/3)
- `BezelChoice`: c1702, c1084 (with physical dot pitch 0.64 mm / 0.42 mm)
- `PaletteChoice`: pepto, colodore, vice

### `Models/DisplaySettings.swift`
`@MainActor final class DisplaySettings: ObservableObject`

Per-device rendering settings, one instance per device UUID, shared via `DisplaySettings.shared(for:)` which keeps a static `[UUID: DisplaySettings]` dictionary. This singleton pattern means the renderer, the toolbar, the context menu, the Settings preferences window, and the bezel knobs all read and write the same object for a given device.

Published fields: `scalingMode`, `filterMode`, `palette`, `tubeInput`, `crtScreenColor`, `crtDirtyGlass`, `showFPS`, `showBezel`, `bezelStyle`, `bezelReflection`, plus monitor controls `monBrightness`, `monContrast`, `monColor`, `monTint`.

Each `didSet` calls `save()`, which serializes a `Snapshot` struct to JSON and writes it to `UserDefaults` under key `"displaySettings.<UUID>"`.

First-run migration: if no per-device key is found, seeds values from the legacy global keys (`"filterMode"`, `"scalingMode"`, etc.) that existed before settings became per-device.

The `loaded` flag prevents `save()` from firing during `init()` before all properties are set.

The `picture: PictureControls` property is the live conduit: knob `live` closures write directly to `picture`, bypassing `@Published` so the renderer sees the value next frame without triggering SwiftUI re-renders.

### `Models/PETSCII.swift`
`enum PETSCII` with a single static method `encode(_ text: String) -> [UInt8]`.

Mapping rules:
- `0x0A`/`0x0D` → `0x0D` (RETURN)
- `a–z` (0x61–0x7A) → 0x41–0x5A (PETSCII upper case, what the C64 calls unshifted letters)
- `A–Z` (0x41–0x5A) → 0xC1–0xDA (PETSCII shifted, what the C64 calls shifted/graphics)
- Space through `@`, digits, `[`, `]` → pass through unchanged (same code in PETSCII)
- `£` (0xA3) → 0x5C
- `^` → 0x5E (up arrow), `_` → 0x5F (left arrow)
- Control codes listed in `controlCodes` (cursor keys, function keys, color codes, home/clear, etc.) → pass through

Note: the mapping is intentionally not a full charset conversion — it covers the characters that actually arrive from a macOS keyboard and from the on-screen keyboard. Unmappable characters are silently dropped.

### `Services/UltimateAPIClient.swift`
`struct UltimateAPIClient`

Thin REST client for the Ultimate's `/v1` API. Every request is built with `makeRequest()` which constructs the URL from `device.baseURL`, appends query items, sets `X-Password` when `device.password` is non-empty, and applies the configured timeout.

All methods are `async throws`. `perform()` throws `APIError.httpError(statusCode, body)` for non-2xx responses and `APIError.deviceErrors` when a nominally successful JSON response contains a non-empty `errors` array.

Endpoints used:
| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/info` | Fetch device product/firmware/hostname/uniqueId |
| PUT | `/v1/machine:reset` | C64 hardware reset |
| PUT | `/v1/machine:reboot` | Full device reboot |
| PUT | `/v1/machine:pause` | Freeze machine |
| PUT | `/v1/machine:resume` | Resume machine |
| PUT | `/v1/machine:poweroff` | Power off machine |
| PUT | `/v1/machine:menu_button` | Press Ultimate menu button |
| GET | `/v1/machine:readmem?address=XXXX&length=N` | Read N bytes of C64 RAM |
| PUT | `/v1/machine:writemem?address=XXXX&data=HHHHH…` | Write bytes to C64 RAM |
| PUT | `/v1/streams/video:start?ip=host:port[&duration=N]` | Start VIC stream |
| PUT | `/v1/streams/video:stop` | Stop VIC stream |
| PUT | `/v1/streams/audio:start?ip=host:port[&duration=N]` | Start audio stream |
| PUT | `/v1/streams/audio:stop` | Stop audio stream |
| POST | `/v1/runners:run_prg` | Upload+run PRG (binary body) |
| POST | `/v1/runners:sidplay` | Upload+play SID (binary body) |
| POST | `/v1/runners:run_crt` | Upload+run cartridge (binary body) |
| POST | `/v1/drives/a:mount[?type=ext]` | Upload+mount disk image (multipart) |

The `typeKeys()` method implements the keyboard injection loop: reads `$C6` (buffer pending count), waits for drain (polls up to 25 × 20 ms), writes up to 10 PETSCII codes to `$0277`, then writes the count to `$C6`. Repeats in chunks of 10.

`flushKeyboardBuffer()` simply writes 0 to `$C6`.

**Important known issue with `/v1/version`:** Early dev used `/v1/version`, which returns `{"version":"0.1"}` with no product or firmware fields. The correct endpoint is `/v1/info`. The bug fix (commit 3bf18e9) changed `fetchInfo()` to use `/v1/info`. Do not revert this.

### `Services/Assembly64Client.swift`
`struct Assembly64Client`

Client for the Assembly64 library API at `https://hackerswithstyle.se/leet`.

Every request must include the `client-id` header with value `"assembly64"`. Without it, the server returns error code 464.

Key types:
- `SearchResult` — composite UI identity (`category:itemID`), name, category, group, handle, year, local/site rating, release/update metadata. `displayGroup` replaces underscores in group names.
- `FileEntry` — id (Int), path, size. `kind` computed property classifies by extension into `FileKind` (prg/disk/sid/cartridge/other).
- `Category` — id, name, description, groupingName, type
- `AQLPreset` / `AQLPresetValue` — server-advertised repository, type, year, recency, rating and sort choices from `/search/aql/presets`
- `Metadata` / `TargetAndPath` — optional source URL and screenshot paths from `/metadata/{id}/{category}`

The **error-in-200 envelope**: the API returns HTTP 200 for some errors, with a JSON body `{"errorCode": N}`. The `getData()` method sniffs small responses (< 200 bytes) and tries to decode `APIErrorBody` before returning data. Error code 463 = bad query syntax; 464 = missing/unknown client-id.

**AQL query syntax:**
- Space-separated `key:value` terms: `name:turrican sort:name order:asc subcat:games`
- Multi-word values MUST be quoted: `name:"last ninja"` — without quotes, the parser splits on space and treats the second word as an unknown stray term, returning error 463
- The app wraps multi-word search text in quotes automatically: `text.contains(" ") ? "\"\(text)\"" : text`

Search flow:
1. `search(query:offset:limit:)` → `GET /search/aql/{offset}/{limit}?query=...` → `[SearchResult]`
2. User selects a result → `entries(itemID:categoryID:)` and (unless cached) `metadata(itemID:categoryID:)` run concurrently
3. User clicks action → `download(itemID:categoryID:fileID:)` → `GET /search/bin/{id}/{cat}/{fileID}` → `Data`
4. "Save ZIP…" → `downloadArchive(itemID:categoryID:)` → `GET /search/zip/{id}/{cat}` → complete entry archive

### `Models/Assembly64LibraryStore.swift`
`@MainActor final class Assembly64LibraryStore: ObservableObject`

Persists favorites, 30-item recent history, named searches (text + category + every AQL facet), and remembered per-file actions at `~/Library/Application Support/Stream64/assembly64-library.json`. Regenerable API metadata is deliberately excluded from this user-state snapshot; see `Assembly64Cache`.

### `Models/Assembly64SearchQuery.swift`

Deterministic, testable AQL composition outside SwiftUI. It strips embedded quotes, quotes multi-word names, appends category/repository/type/year/rating/recency facets, and always includes sort/order. `hasConstraint` permits filter-only discovery but rejects an unconstrained default search.

### `Services/Assembly64Cache.swift`
`actor Assembly64Cache`

Serializes access to a bounded cache under `~/Library/Caches/Stream64/`. Assembly64 metadata expires after 24 hours; CSDB preview descriptors expire after seven days. Each cache holds at most 100 records. Corruption or OS eviction only causes refetching — favorites and saved searches are unaffected.

### `Services/CSDBPreviewClient.swift`

Fallback for entries whose Assembly64 metadata has no screenshot/source link. It is called only when the selected category registry says `type == "csdb"`, reads the first `ScreenShot` from CSDB's release XML, validates HTTP(S) URLs, and links to the corresponding CSDB release page.

### `Services/Assembly64ArchiveInspector.swift`

Uses ZIPFoundation 0.9.20 to inspect complete-entry archives in memory. Before listing or extraction it rejects oversized archives, more than 500 entries, absolute/traversal/duplicate paths, symbolic links, oversized members/totals and suspicious compression ratios. Selected regular files are CRC-checked and extracted directly to bounded `Data`; archive paths are never written to disk.

### `Services/DeviceSession.swift`
`@MainActor final class DeviceSession: ObservableObject`

The core per-device controller. Owns `VideoReceiver`, `AudioReceiver`, `UltimateAPIClient`, and `DisplaySettings`. Created and cached by `SessionManager`.

See section 5 for the full connection state machine.

Also defines:
- `TransferStatus` enum: `.uploading(String)`, `.done(String)`, `.failed(String)` — shown in the transfer banner overlay
- `MountBehavior` enum: Codable/Equatable `.mountOnly`, `.mountAndRun`
- `LoadOutcome` enum: successful `.running`, `.mounted`, `.booting`, `.playing` result returned by `loadData()` so library history/preferences are never recorded after failed device operations
- `LocalNetwork.primaryIPv4Address()` — walks `getifaddrs`, prefers `en0`, falls back to any `en*` interface. Used to determine where to tell the device to stream.

### `Services/SingleInstanceLock.swift`

Uses a non-blocking POSIX `flock` on `~/Library/Application Support/Stream64/instance.lock`. This is required for `swift run`, where macOS does not provide normal app-bundle single-instance behavior. The lock file contains the owner PID so a rejected second launch can activate the existing app. The OS releases the advisory lock on normal exit or crash; stale file contents are harmless.

### `Services/VideoReceiver.swift`
`final class VideoReceiver`

UDP listener using `NWListener` / `NWConnection` on a private `DispatchQueue`. Assembles 4bpp video packets into a `384 × 272` byte buffer (one byte per pixel = palette index 0–15).

Packet format (all little-endian):
```
u16 sequence      — packet sequence number (not used for assembly)
u16 frame         — frame number
u16 lineField     — bit 15 = last packet of frame; bits 14:0 = start line
u16 pixelsPerLine — always 384
u8  linesPerPacket — number of source lines in this packet
u8  bitsPerPixel  — always 4
u16 encoding      — not used
<payload>         — pixelsPerLine * linesPerPacket / 2 bytes, 4bpp packed
                    low nibble = left pixel, high nibble = right pixel
```

`handlePacket()` validates the header (bpp==4, pixelsPerLine==384, size sufficient, line range fits buffer), unpacks nibbles into `frameBuffer`, then calls `publishFrame()` when the last-packet bit is set.

`packetsReceived` is a lifetime counter written on the receive queue and read racily from other threads. Connect snapshots a per-attempt baseline and looks for increases; comparing with zero would mistake packets from an old listener session for current liveness.

FPS statistics are computed in `publishFrame()`: frame counter / elapsed seconds, reported via `onStats` once per second.

Debug mode: set env var `UV_DEBUG=1` to enable periodic `NSLog` dumps of packet/frame counts.

### `Services/AudioReceiver.swift`
`final class AudioReceiver`

UDP listener that feeds an `AVAudioSourceNode` pull-render model. See section 4 for the full audio data path.

Key fields:
- `ring`: `[Float]` of capacity `sampleRate * 2` (~2 s at 47983 Hz), interleaved stereo
- `readIndex`, `writeIndex`, `framesAvailable`: ring buffer state, all guarded by `os_unfair_lock`
- `primed`: false until `framesAvailable >= targetFrames` (the jitter buffer depth)
- `muted`: silences the `AVAudioEngine.mainMixerNode` without stopping the stream
- `rfAudioEnabled`: written from main thread, read on audio thread — torn reads are harmless (it's just a mode flag)

RF filter state (all audio-thread-only): `rfLowState` + `rfLowState2` (two-pole LP), the `.l/.r` halves of `rfHighState`/`rfHighPrev` (two cascaded HP poles), `rfNoiseSeed` (LCG PRNG), and `rfHumPhase`. Filter state resets whenever the audio engine starts.

### `Rendering/MetalFrameRenderer.swift`
`final class MetalFrameRenderer: NSObject, MTKViewDelegate`

All Metal rendering. Shaders are embedded as a source string and compiled at runtime via `makeLibrary(source:)`; XCTest instantiates the renderer to catch shader errors. Four pipeline states share `vertexMain`. The renderer owns triple-buffered current frames, a 12-slice indexed history for Amber persistence, per-monitor physical shadow-mask pitch, filtered screenshot targets, and the packaged photographic dirt texture (with transparent fallback).

See section 7 for the full rendering breakdown.

### `Views/ContentView.swift`
Contains `SessionManager` (the cache class), `ContentView`, `MultiViewerGrid`, `ViewerTile`, `DeviceStatusBadge`, `DeviceSidebar`, `EmptyStateView`, and `ViewerPane`.

`SessionManager` is defined here (not in Services) because it is an app-level concern that ties together the session cache, audio policy, and multi-drop. It is held as `@StateObject` in `Stream64App`.

`ViewerPane` is the main single-device view. It observes both `session` and `display` (the per-device `DisplaySettings`) directly so `updateNSView` in `VideoView` fires when display settings change.

The `displayBinding(_:)` helper creates one-way bindings into `DisplaySettings` for toolbar pickers — writes go through, reads don't make `ViewerPane` observe the whole object indiscriminately.

Fullscreen arrow key monitor: `ContentView` installs a `NSEvent.addLocalMonitorForEvents` for `.keyDown` when entering fullscreen with multiple devices. Keys 123 (left arrow) and 124 (right arrow) with no modifiers switch the selected device and are consumed (return `nil`). All other events pass through to the video view (which forwards them to the C64). The monitor is removed on fullscreen exit.

Fullscreen cursor monitor: the fullscreen `NSWindow` temporarily enables `acceptsMouseMovedEvents`. A local `.mouseMoved` monitor reveals the pointer and restarts a five-second cancellable task; expiry hides it using balanced `NSCursor.hide/unhide` calls. Exiting fullscreen, view teardown, or app deactivation always cancels the task and restores the cursor/window setting. Returning to the active app schedules hiding again only if still fullscreen.

### `Views/VideoView.swift`
`struct VideoView: NSViewRepresentable` wrapping `KeyCapturingMTKView: MTKView`.

`VideoView` observes `session` and `display` (obtained from `session.display`). This is critical: if it only observed `session`, settings changes would only reach `updateNSView` when the session publishes — which it does not do for display settings. The direct observation of `DisplaySettings` guarantees `updateNSView` fires immediately when any visual setting changes.

`KeyCapturingMTKView` overrides:
- `acceptsFirstResponder` → true
- `mouseDown` → calls `window?.makeFirstResponder(self)` so clicking the video grabs keyboard focus
- `keyDown` → maps macOS key codes to PETSCII/control sequences via `c64Text(for:)`, calls `onKeyText`
- `viewDidMoveToWindow` → installs/removes `NSWindow.didChangeOcclusionStateNotification` observer

**Occlusion fallback:** When a window is fully occluded (e.g. a Settings window is on top of the viewer), macOS pauses the `MTKView` display link. The fallback is a `Timer` firing at 1/50 s intervals that calls `draw()` directly. This keeps frames presenting for background sessions in the grid view. The timer runs on `RunLoop.main` in `.common` mode.

### `Views/MonitorBezelView.swift`
`struct MonitorBezelView<Content: View>` and `struct KnobDial`.

The bezel is drawn in pure SwiftUI using `RoundedRectangle`, `LinearGradient`, and `ZStack`. Geometry is computed relative to the tube opening (4:3 aspect), with a `rim` fraction (5.5%) and `chin` fraction (16% for 1702, 14% for 1084S). A `GeometryReader` fits the case into the available space.

The 1702 control door is a `@State private var doorOpen: Bool` toggled by `onTapGesture` on the control strip. When open, five `KnobDial` views appear for VOLUME, BRIGHT, COLOR, TINT, CONTRAST.

`KnobDial` uses two closures, not one:
- `live: (Double) -> Void` — called every drag tick, updates `PictureControls` directly (no SwiftUI publish)
- `commit: (Double) -> Void` — called once on drag end, writes to `DisplaySettings` (triggers save)

This split is the key to smooth knob response. If `commit` were called on every tick, every write to `DisplaySettings.monBrightness` would publish `AppSettings` changes and re-render the entire window — far too slow for 60 Hz drag.

### `Views/Assembly64View.swift`
`struct Assembly64View` — the Assembly64 browser window.

A compact vertical layout with a fixed 300-point results area (header + roughly ten rows + status) above metadata/file details. Keeping the result area fixed avoids a giant table in tall windows and leaves the remaining height for entry contents. The `sessionProvider` closure (passed from `Stream64App`) bridges the browser to the live `SessionManager` — the browser doesn't hold sessions itself, it just looks them up for the selected device at load time.

The segmented Search/Favorites/Recent picker changes the table's local source without touching the selected machine. Search mode supports server-advertised repository/file-type/year/rating/recency/sort facets plus category and free text. A query may be filter-only; `runSearch()` only rejects a truly unconstrained default search.

Selecting an item starts a cancellable task that loads files and metadata concurrently. Cached metadata appears immediately. Selection changes cancel the prior task and every state write verifies the selected composite ID, preventing a slow earlier response from overwriting the new item.

The detail pane shows optional preview/source metadata, complete entry contents, remembered load actions, and "Save ZIP…". Favorites, recent history, saved searches, action preferences, and metadata cache live in `Assembly64LibraryStore`.

### `Views/OnScreenKeyboardView.swift`
`struct OnScreenKeyboardView` — full C64 keyboard layout.

Each `Key` has: `label`, `code: UInt8`, optional `shiftedLabel`/`shiftedCode`, and `width` (relative units, standard key = 1.0).

Shift is sticky (`@State private var shifted`): clicking SHIFT toggles the state, clicking any other key sends the shifted code and resets shifted to false.

CTRL and RESTORE have code 0x00 and are disabled (`isDead = true`) — they cannot be sent through the KERNAL buffer because the buffer holds character codes, not scan codes.

### `Views/StreamContextMenu.swift`
`struct StreamContextMenu`

Right-click menu with the full per-stream control set. Deliberately does NOT `@ObservedObject` the session: a live-observing menu would be re-rendered every time `fps` publishes (once per second), which collapses open submenus. Instead, state is snapshotted at menu-open time. Writes go through `bind(_:)` snapshot bindings into `DisplaySettings`.

### `Views/DeviceEditSheet.swift`
`struct DeviceEditSheet` — add/edit device sheet with connection test.

Mode is `.add` (takes an optional `suggested` device for pre-filling ports) or `.edit(UltimateDevice)`. The test button calls `UltimateAPIClient.fetchInfo()` and shows the product+firmware string on success.

### `Views/SettingsView.swift`
`struct SettingsView` — tabbed preferences window.

The Video tab shows `DeviceVideoSettings` which observes the `DisplaySettings.shared(for:)` for the currently selected device. Switching devices in the main window while Settings is open updates what you see in the Video tab (because `deviceStore.selectedDevice` changes, `VideoSettingsTab` rebuilds, and `.id(device.id)` forces `DeviceVideoSettings` to reinit with the new device's settings).

### `Views/HelpView.swift`
`struct HelpView` and `enum HelpTopic`.

In-app documentation, content stored as multiline string literals with markdown formatting. Topics: Getting Started, Devices & Connection, Viewing & Full Screen, Rendering & CRT Simulation, Monitor Bezel, Keyboard Input, Loading Files, Assembly64 Library, Multiple Devices, Machine Control, Troubleshooting. Ships with the app, works offline.

### `Tests/Stream64Tests/Stream64Tests.swift`

XCTest coverage includes AQL composition, composite Assembly64 identity, persisted favorites/search/history/action state, ZIP traversal/symlink/size/count safety and selective extraction, CSDB XML preview parsing, backward-compatible display snapshots, CRT enum/dot-pitch constants, single-instance locking, and runtime compilation of every embedded Metal shader.

### Packaging

- `Packaging/Info.plist` — bundle identity/version placeholders, macOS 14 minimum, local-network description and HTTP-local-device ATS policy.
- `Scripts/build-release.sh` — cross-compiles `ARCH=arm64|x86_64`, assembles standard app resources, validates Mach-O architecture, ad-hoc signs/verifies app and DMG, creates ZIP/DMG and SHA-256 files.
- `Package.resolved` pins ZIPFoundation 0.9.20.
- `Sources/Stream64/Resources/dirty-glass-mask.png` is the photographic RGBA CRT contamination material copied into packaged app resources.

---

## 4. The Data Path

### 4.1 Video

**Packet format.** The Ultimate sends VIC frames as a sequence of UDP packets. Each packet has a 12-byte header (all little-endian):
```
offset 0: u16 sequence number
offset 2: u16 frame number
offset 4: u16 lineField (bit 15 = last packet of frame; bits 14:0 = start line number)
offset 6: u16 pixelsPerLine (always 384)
offset 8: u8  linesPerPacket
offset 9: u8  bitsPerPixel (always 4)
offset 10: u16 encoding (ignored)
offset 12: payload — (pixelsPerLine × linesPerPacket / 2) bytes
```

Pixel encoding: 4bpp packed, **low nibble = left pixel**, high nibble = right pixel. The palette index is 0–15.

**Assembly.** `VideoReceiver.handlePacket()` validates the header, then unpacks nibbles into a static `[UInt8]` frame buffer of 384 × 272 = 104,448 bytes. Lines from multiple packets accumulate into the buffer; when `lastPacket` is set, the completed frame is passed to `onFrame`.

The frame is a flat byte array: `buffer[y * 384 + x]` = palette index at pixel (x, y). No inter-frame dependencies; every packet stands alone.

**Metal upload.** `MetalFrameRenderer.submitFrame()` stores the `Data` in `pendingFrame` under `textureLock`. On the next `draw()` call (display link, ~60 fps), the renderer rotates to the next texture in the triple-buffer ring and calls `replace()` to upload. The CPU then reads `pendingFrame` and clears it, freeing the data.

**Why triple-buffer?** With expensive fragment shaders (CRT modes), the GPU may still be reading a texture when the next frame arrives. `MTLTexture.replace()` is a CPU write that is not synchronized with the GPU. On Apple Silicon this didn't tear with cheap shaders, but CRT Composite and RF modes are slow enough to cause visible tearing on the single-texture arrangement. Three textures ensure the upload always targets a texture not in any in-flight command buffer.

**Palette lookup.** The fragment shader reads the index texture (R8Uint format), uses the index to look up the 16×1 RGBA palette texture, and outputs the result. The CPU never converts indexed pixels to RGB — that work stays entirely on the GPU.

**Scaling.** The `computeScale()` method returns a 2D scale factor for the vertex shader. The C64's pixels are not square: 384×272 raw pixels display at 4:3 on a real television. Scaling targets display aspect 4/3, not pixel aspect 384/272 (~1.41). Modes:
- `fill`: scale = (1, 1), picture stretches to fill the Metal view
- `aspectFit`: compute the largest 4:3 rectangle fitting in the drawable size
- `integer`: largest integer multiple of the source height (272) that fits, width follows 4:3

### 4.2 Audio

**Stream format.** The audio stream is 16-bit signed stereo little-endian at 47983 Hz (the Ultimate's actual PAL-derived sample rate). Each UDP packet has a 2-byte header (sequence number) followed by 192 stereo sample pairs = 384 samples = 768 bytes per packet.

**Pull model.** `AudioReceiver` uses `AVAudioSourceNode` with a render callback — the audio engine pulls from the ring buffer rather than the app pushing to a buffer. This is the correct low-latency approach: the hardware dictates timing, and the app just supplies data.

`AVAudioFormat` is initialized with `standardFormatWithSampleRate:channels:` which gives non-interleaved (deinterleaved) stereo float PCM. `AVAudioEngine` node connections require non-interleaved format. The ring buffer stores interleaved stereo (two floats per frame), and the render callback deinterleaves while copying: `left[i] = ring[readIndex * 2]`, `right[i] = ring[readIndex * 2 + 1]`.

**Ring buffer.** Capacity is `sampleRate * 2` frames (~2 seconds). The lock is `os_unfair_lock` (not `NSLock`) because the audio thread is real-time and cannot block waiting for a priority-inversion-prone lock. The lock is heap-allocated with `UnsafeMutablePointer` (required because `os_unfair_lock` must not be moved in memory).

**Jitter buffer.** The ring buffer doubles as a jitter absorber. `bufferSeconds` (default 60 ms) sets the target buffering depth. The render callback will output silence until `framesAvailable >= targetFrames` (priming phase), then starts outputting. On every render call, if `framesAvailable > targetFrames + slackFrames`, the excess is dropped by advancing `readIndex` — this bounds latency and prevents the permanent delay ratchet that accumulates if frames arrive faster than they play.

An underrun (ring buffer ran dry) outputs silence and resets `primed = false`, so the buffer re-primes before output resumes. This produces a clean short silence rather than crackling partial frames.

**RF audio filter.** When `rfAudioEnabled` is true (set when `tubeInput == .rf` AND a CRT filter is active), the render callback applies `applyRFFilter()` in-place after reading from the ring buffer. The filter runs entirely on the audio thread with no allocations:

1. Mono fold: `s = (left + right) * 0.5`
2. Two-pole ~3.3 kHz low-pass: two cascaded one-pole IIR filters, `lpAlpha = 0.30` (designed for 47983 Hz). Two poles gives 12 dB/oct rolloff — one pole is too gentle against SID content.
3. Two-pole ~330 Hz high-pass: cascaded `hpAlpha = 0.958` poles give 12 dB/oct bass roll-off, emulating an inexpensive 1980s TV's small internal speaker
4. Tanh soft-clip: `tanh(s * 2.2) * 0.85` — small TV amplifiers distort early
5. White noise hiss: LCG PRNG (`rfNoiseSeed = rfNoiseSeed * 1664525 + 1013904223`), low-passed through the same first LP pole, added at 0.035 amplitude
6. 50 Hz mains hum: `sin(rfHumPhase)` at 0.010 amplitude, phase advanced each sample by `2π × 50 / 47983`

The result is written to both `left[i]` and `right[i]` (mono output).

### 4.3 Keyboard Injection

The Ultimate's REST API has no keyboard endpoint. This was verified against firmware 3.14 and the device's own web UI. The only available mechanism is DMA memory access: reading and writing the C64's RAM directly while the machine is running.

**The KERNAL keyboard buffer.** The C64 KERNAL maintains a 10-byte circular buffer of pending keystrokes at `$0277–$0280`. The byte at `$C6` (zero page) is the number of bytes currently pending. When the KERNAL interrupt service routine processes a keystroke, it reads the next byte from the buffer and decrements `$C6`.

**Injection procedure** (in `UltimateAPIClient.typeKeys()`):
1. Read `$C6` (1 byte via `GET /v1/machine:readmem?address=00C6&length=1`)
2. If non-zero, wait 20 ms and re-poll, up to 25 times (500 ms total drain wait)
3. Write up to 10 PETSCII codes to `$0277` via `PUT /v1/machine:writemem?address=0277&data=...`
4. Write the chunk count to `$C6` to tell the KERNAL how many keys are pending
5. Advance index by chunk size, repeat from step 1 for remaining codes

**Why drain polling matters but isn't strictly required.** Programs that reuse zero page (most do when not in BASIC) may have `$C6` contain a non-zero value unrelated to the keyboard buffer. Overwriting is safe because: (a) keys are flushed at all machine-state boundaries (reset, PRG load), (b) a stuck non-zero value proves nothing. The polling loop is a best-effort courtesy to avoid overwriting keys the KERNAL hasn't consumed yet.

**Serialized queue.** `DeviceSession` maintains a `keyQueue: [UInt8]` and a `keyWorker: Task`. All calls to `sendKeys()` / `sendKeyCodes()` append to the queue; the worker drains it. At most one worker runs at a time. This prevents concurrent `typeKeys()` calls from racing on the keyboard buffer. On failure, the worker retries once after 300 ms, then reports via `transferStatus`.

**Flushing at boundaries.** `flushPendingKeys()` cancels the worker, clears the queue, and writes 0 to `$C6`. Called before: `reset()`, `reboot()`, `runPRG()`. This prevents half-typed text from replaying after a program starts.

**Limitation.** Only programs that read keys through the KERNAL receive injected keystrokes. This includes BASIC, all KERNAL-based utilities, and most productivity software. Games that scan the keyboard hardware matrix by reading CIA registers (the vast majority of action games) do not.

### 4.4 File Loading

**PRG.** `POST /v1/runners:run_prg` with `Content-Type: application/octet-stream` and the binary PRG data as body. The firmware resets the machine, DMA-loads the PRG, and runs it.

**Disk images.** `POST /v1/drives/a:mount` with `Content-Type: multipart/form-data`. The multipart body has one part with `name="file"` and a `filename` parameter. A `?type=ext` query parameter can hint the disk format; the firmware can usually infer it from the filename extension.

**SID tunes.** `POST /v1/runners:sidplay` with binary body. The firmware starts its built-in SID player.

**Cartridge images.** `POST /v1/runners:run_crt` with binary body.

**Mount & Run boot chain.** When `MountBehavior == .mountAndRun`:
1. `mountDisk()` — uploads and mounts in drive A
2. `flushPendingKeys()` — clear any pending input
3. `client.reset()` — hardware reset, BASIC comes up
4. `Task.sleep(for: .seconds(3))` — wait for BASIC to complete its startup banner
5. `typeKeys(PETSCII.encode("load\"*\",8,1\r"))` — inject the load command
6. `Task.sleep(for: .seconds(1))` — wait for load to start
7. `typeKeys(PETSCII.encode("run\r"))` — inject RUN

The 3-second delay is empirical. BASIC needs time to print the startup banner and become responsive to keyboard input. Too short = the keystrokes land before BASIC is ready; too long = unnecessary wait.

**Multi Drop.** `SessionManager.loadFileOnAllConnected()` iterates connected sessions and calls `loadFile(at:)` in parallel `Task`s. Triggered from `ViewerPane` and `ViewerTile` when the drop is performed with `NSEvent.modifierFlags.contains(.control)`.

---

## 5. Connection State Machine

### States

```
.disconnected
    │
    │ connect() called (auto-connect .task, Retry button, user action)
    ▼
.connecting
    │
    ├── probeReachability() fails (no REST response in 2 × 2 attempts)
    │       ▼
    │   .unreachable   ← no automatic retries; user must act
    │
    ├── receivers start OK, startStreaming() succeeds
    │       ▼
    │   .connected(info: "Product · Firmware")
    │
    └── startStreaming() throws "Network Host Resolve Error" (twice)
        or other failure
            ▼
        .error(message)
            │
            ├── User clicks Retry → back to .connecting
            └── User clicks "Reboot Device & Retry" → rebootAndReconnect()
```

The `error` state also carries the "Reboot Device & Retry" recovery path as a button in the error panel overlay. This is specifically for the firmware 3.14 wedged-stack scenario.

### `probeReachability()`

Uses a separate `UltimateAPIClient` with a 2-second timeout (not the session's normal timeout). Makes up to 2 attempts with a 400 ms gap between them. Returns the `DeviceInfo` on success (product, firmware version, hostname, uniqueId) — this doubles as the identity fetch so `connect()` doesn't need to make another API call.

### Stream pickup logic

After opening UDP listeners, the connect flow snapshots each receiver's lifetime packet counter, then polls for increases for up to 600 ms (6 × 100 ms sleeps):
```swift
let videoPacketBaseline = videoReceiver.packetsReceived
let audioPacketBaseline = audioReceiver.packetsReceived
for _ in 0..<6 {
    try await Task.sleep(for: .milliseconds(100))
    videoLive = videoReceiver.packetsReceived > videoPacketBaseline
    audioLive = audioReceiver.packetsReceived > audioPacketBaseline
    if videoLive && (audioLive || !settings.audioEnabled) { break }
}
```

The baseline is essential: receiver objects survive listener restarts, so `packetsReceived > 0` can describe an old session and falsely suppress `stream:start`. Video and audio are checked **independently**. If the app was restarted while the device was already streaming (common workflow), both streams may be live immediately. If only video is live, audio still gets (re)started. If only audio is live, video still gets (re)started.

`startStreaming(video:audio:)` takes optional booleans: only the streams that need starting are started. This avoids disturbing a working stream.

**Always stop, settle, then start.** Even when starting a fresh stream, `startStreaming()` stops every requested stream first, waits one second, then starts video/audio. After a cold power-on, firmware may acknowledge a bare start but send no packets. C64 Ultimate 1.1.0 also needs teardown time: an immediate start after stop can return "Network Host Resolve Error" for a literal IP, while the same stop → 1 s wait → start sequence succeeds. Stop failures are ignored because the stream may not have been running.

### `watchForSilentStream` watchdog

After `connect()` succeeds, a bounded watchdog Task waits 4 seconds and checks if `fps < 1`. If so, it calls `startStreaming()` and recurses with `attempt + 1`. After 3 failed attempts it gives up with a `transferStatus = .failed(...)` banner. The guard condition `!streamsStoppedByUser` prevents the watchdog from fighting explicit stop operations.

### `startStreaming()` / `stopStreams()` / `restartStreams()`

- `stopStreams()`: tells the device to stop sending, resets fps and isStreaming, sets `streamsStoppedByUser = true`
- `restartStreams()`: clears `streamsStoppedByUser`, calls `startStreaming()`, kicks `watchForSilentStream()`
- These do not tear down the session (no disconnect). REST control, keyboard, and file loading continue working. The picture freezes on the last received frame.

### Reboot flow

`reboot()` calls `client.reboot()`, then polls `fetchInfo()` for up to 15 seconds. When the device responds, it calls `startStreaming()` to re-arm. The device reboot kills the streaming stack — streams must be re-armed after every reboot.

`rebootAndReconnect()` is the recovery path for a wedged device (error state before connection was established). It calls `reboot()`, polls for 20 seconds, then runs the full `connect()` flow.

### Reentrancy guard

`connect()` has a `connecting: Bool` flag (not `@Published`) that prevents interleaved runs. Without this, auto-connect from grid tiles + user Retry + the connect watchdog could all fire simultaneously. Concurrent `AudioReceiver.start()` calls raced on the CoreAudio engine and produced error 35 (kAudioHardwareIllegalOperationError).

### Mid-session disconnect detection & automatic reconnect

Everything above (`watchForSilentStream`, cold-boot stop/start, etc.) assumes the REST API stays reachable — it only handles "streams start but no packets arrive." None of it catches the device (or the network path to it) dropping out entirely while `state == .connected`. This is what `AppSettings.reconnectAutomatically` now drives.

`DeviceSession` runs a `healthMonitor: Task` for its entire lifetime (started in `init()`, never cancelled — cheap to leave running since it no-ops while not connected):

```swift
while !Task.isCancelled {
    try? await Task.sleep(for: .seconds(5))
    guard isConnected else { consecutiveFailures = 0; continue }
    let probe = UltimateAPIClient(device: device, timeout: 3)
    if (try? await probe.fetchInfo()) != nil {
        consecutiveFailures = 0
    } else {
        consecutiveFailures += 1
        if consecutiveFailures >= 2 { consecutiveFailures = 0; handleConnectionLost() }
    }
}
```

Two consecutive misses (~10 seconds) before acting — a single dropped probe on a flaky network is not a disconnection, and firing on the first miss would false-positive constantly on a home Wi-Fi link.

`handleConnectionLost()` stops both receivers (their packets are now stale) and branches on the setting:
- `reconnectAutomatically == true`: sets `state = .connecting` (reusing the existing UI, which already renders a spinner/"Connecting…" for that case — no new `ConnectionState` was added) and starts `reconnectTask`.
- `reconnectAutomatically == false`: sets `state = .error("Connection to the device was lost.")`, same as any other failure — the user clicks Retry, exactly like before this feature existed.

`reconnectTask` is a loop that repeatedly calls the *existing* `connect()` (full reachability probe, receiver setup, stream pickup — no duplicate logic) with exponential backoff (2s → 3s → 4.5s… capped at 30s):

```swift
while !Task.isCancelled {
    if isConnected { return }
    await connect()
    if isConnected { return }
    guard settings.reconnectAutomatically else { return }
    try? await Task.sleep(for: .seconds(delaySeconds))
    delaySeconds = min(delaySeconds * 1.5, 30)
}
```

Checking `isConnected` both before and after the `connect()` call (not just after) matters: it closes a race where a user-initiated Retry succeeds while `reconnectTask` is asleep — without the pre-check, the loop would wake up and call `connect()` again on an already-good connection, which would flash `.connecting` and briefly restart the receivers for no reason.

Two cancellation points keep the automatic loop from fighting a manual action:
- `connect()` cancels `reconnectTask` at entry — a user-initiated Retry (or the grid's auto-connect `.task`) always supersedes a pending automatic attempt. (Cancelling the task from inside a closure that task itself is running is safe here — see the loop's `Task.isCancelled` checks.)
- `disconnect()` cancels `reconnectTask` — an explicit Disconnect must stick; the health monitor won't refight it because `isConnected` is now false.

This is deliberately layered on top of the existing state machine rather than adding a `.reconnecting` case: the UI, the retry buttons, and the reboot-recovery path all already handle `.connecting` correctly, and a distinct state would mean touching every view that switches on `ConnectionState` for no real behavioral gain.

### Audio startup resilience

`startAudioIfEnabled()` returns `Bool` (success/failure). If audio fails to start, `connect()` proceeds with video-only and calls `recoverAudioQuietly()`, which retries `startAudioIfEnabled()` four times at 1-second intervals in the background. Only after all retries fail does it show a `transferStatus = .failed(...)` banner.

CoreAudio error 35 occurs when `AVAudioEngine.start()` is called in rapid succession — a brief `Thread.sleep(0.25)` and one retry in `AudioReceiver.start()` clears it. This is called synchronously on the `connect()` Task thread, not the audio thread.

### `isStreaming` vs. `isConnected`

- `isConnected` reflects the state machine (`case .connected`)
- `isStreaming` reflects whether video packets are actually arriving (measured from `onStats`)
- The staleness monitor sets `isStreaming = false` when `onStats` stops firing for 3+ seconds (stream died silently)

These are independent: `isConnected = true, isStreaming = false` means "REST API is up, but no video packets" — shown in the sidebar status dot as blue (Online) vs. green (Streaming).

FPS publishes only on changes ≥ 0.5 (`if abs(fps - self.fps) >= 0.5`). This avoids per-second re-renders of every observer, which caused open context menus to rebuild and collapse submenus.

---

## 6. Per-Device Display Settings

### The DisplaySettings vs. AppSettings split

`AppSettings` holds settings that apply globally: audio hardware (volume, buffer size, enabled), network (timeout, stream duration), and general preferences (reconnect, keyboard capture, confirm destructive actions). All backed by `@AppStorage` (UserDefaults).

`DisplaySettings` holds settings that are specific to how one device's stream looks: filter mode, scaling, palette, input signal, bezel style and visibility, reflection, and the five picture-control values. Persisted per device UUID as a JSON blob in UserDefaults under `"displaySettings.<UUID>"`.

The split matters for multi-device: one machine can run CRT Tube + RF while another runs Sharp + S-Video. `AppSettings` changes (volume slider) affect all devices; `DisplaySettings` changes affect only the device that owns that instance.

### The singleton pattern

`DisplaySettings.shared(for:)` returns (or creates and caches) one instance per device UUID in a static dictionary. This ensures that:
- The renderer (via `VideoView`) and the toolbar pickers share the same object
- The Settings window (via `VideoSettingsTab`) and the context menu share the same object
- Changes from any control surface take effect immediately on all others

### Why sessions need @StateObject in SessionManager

`DeviceSession` holds a `DisplaySettings` reference (`display`). `SessionManager` caches sessions by UUID. `SessionManager` itself must be held in `@StateObject` at the app level — originally `ContentView` held the session manager, but view struct rebuilds would recreate it.

In SwiftUI, `@State` and plain properties on a `View` struct are recreated whenever the view struct is recreated (which happens on any `@ObservedObject` publish). `@StateObject` survives view rebuilds and is tied to the view's identity in the view tree. When `AppSettings`, `DeviceStore`, or any other observed object published, `ContentView` would rebuild, and a plain `var sessionManager = SessionManager()` would silently create a second session for each device — two `VideoReceiver`s, two `AudioReceiver`s, two renderers. The result was black screens and doubled audio (phantom streams).

The fix was lifting `SessionManager` to `@StateObject` in `Stream64App` (which is never recreated) and passing it via `.environmentObject()`. The same fix applies to `DeviceStore` and `AppSettings` — all three are app-level state.

### Persistence

`save()` is guarded by `loaded = true` (set at the end of `init()`). This prevents the `didSet` triggers on all the property initializations from writing back to UserDefaults before the object is fully constructed.

The `Snapshot` codable struct contains all fields. Encoding is JSON (via `JSONEncoder`). Decoding is done at init time directly from `UserDefaults.standard.data(forKey:)`.

### Legacy migration

If no per-device key is found for a UUID, `init()` reads the legacy global `UserDefaults` keys (`"filterMode"`, `"scalingMode"`, `"palette"`, etc.) and uses them as initial values. This preserves the look a user had before settings became per-device. The global keys are never deleted — they just stop being the source of truth once a per-device key exists.

### PictureControls bypass pattern

For the monitor knob drags, writing to `DisplaySettings.monBrightness` would:
1. Trigger `didSet { picture.brightness = Float(monBrightness); save() }`
2. Trigger `objectWillChange` publish on `DisplaySettings`
3. Cause every view observing `DisplaySettings` to re-render
4. At 60 Hz drag, this would re-render the entire window 60 times per second

Instead, `KnobDial.live` writes directly to `display.picture.brightness` (the plain `PictureControls` object), bypassing SwiftUI. The renderer reads `picture` every frame via `var picture: PictureControls?`. `KnobDial.commit` (fires once on drag end) writes `display.monBrightness = value` which publishes once and persists.

---

## 7. Metal Rendering

### Pipeline architecture

All shader code lives in `MetalFrameRenderer.shaderSource` (a static String constant), compiled at app launch via `device.makeLibrary(source:options:)`. There is no separate `.metal` file. Four `MTLRenderPipelineState` objects are compiled from the same vertex function and four different fragment functions.

The vertex shader (`vertexMain`) generates a fullscreen quad from a triangle strip of 4 vertices (positions hardcoded in the shader, indexed by `vid`). It applies a 2D scale from `uniforms.scale` so the output is letterboxed/scaled correctly without needing vertex buffers.

### Uniforms

```swift
struct Uniforms {
    var scale: SIMD2<Float>      // vertex scale for letterboxing
    var reflection: Float        // 1.0 = tube reflection on, 0.0 = off
    var signal: Float            // 0 = S-Video, 1 = Composite, 2 = RF
    var time: Float              // frame counter / 60, cycles over 60 s
    var brightness: Float        // 0.5 = neutral
    var contrast: Float          // 0.5 = neutral
    var saturation: Float        // 0.5 = neutral
    var tint: Float              // 0.5 = neutral
    var phosphorColor: Float     // 0 = color, 1 = amber, 2 = green, 3 = B&W
    var dirtyGlass: Float        // 1 = years-of-neglect grime layer
    var padding: Float           // alignment
}
```

Uniforms are passed via `setVertexBytes` and `setFragmentBytes` (both). The vertex shader uses only `scale`; the fragment shaders use all fields.

`time` is `Float(frameIndex % 3600) / 60.0`, giving a 60-second floating-point cycle. The modulo prevents eventual float precision loss and keeps the animation loop finite. RF artifacts (snow, interference line) are animated using `time`.

Picture control values are read from `picture?.brightness ?? 0.5` etc., bypassing SwiftUI as described in section 6.

### Sharp filter (`fragmentMain`)

Point-samples the index texture at the integer-nearest texel, looks up in the palette texture, applies `applyPicture()`. No interpolation. Cheapest mode.

### Smooth filter (`fragmentSmooth`)

Manual bilinear interpolation in palette space: samples the four surrounding index texels, converts each to RGB via palette lookup, then bilinear-blends the four RGB values. This blends in perceptual (linear) RGB space, not in palette index space (which would be meaningless). The sampler state is irrelevant here; all sampling is done manually.

### CRT filter (`fragmentCRT`) — flat screen

`crtShade()` static function:

1. **Signal simulation** (when `signal > 0.5`): calls `compositeSample()`
2. **Soft horizontal bloom**: averages one-texel-left and one-texel-right neighbors at 25% mix — emulates horizontal phosphor glow
3. **Scanlines**: `sin(row * π * 2) * 0.5 + 0.5` gives a value of 1 at scanline centers and 0 between. The darkness multiplier is `mix(0.35, 0.15, luminance)` — bright areas mask the scanlines while dark areas show deep gaps. For Amber/Green only, brightness above 0.62 ramps a beam-current bloom: scanline darkness falls to 22% of normal at the end stop and 18% of neighboring blur spills into the gaps, reproducing an overdriven monochrome tube whose scanlines light into each other.
4. **Shadow-mask phosphors**: the selected monitor's published pitch (1084S 0.42 mm; 1702 0.64 mm) is converted to destination pixels from the scaled width of a 13-inch 4:3 tube (~264.2 mm visible width). RGB triads use that period, alternating rows are staggered by one-sixth pitch, and vertical cosine modulation forms soft oval dots. Pitch clamps to a minimum 3 pixels when the drawable cannot resolve a full triad without severe aliasing.

Then `applyPicture()` applies monitor controls, `applyPhosphorColor()` applies Color/Amber/Green/Black & White when selected, and `dither()` adds ±0.5 LSB noise. Sharp/Smooth deliberately ignore `phosphorColor`; all UI controls are disabled unless `filterMode` is `.crt` or `.crtTube`.

### CRT Tube filter (`fragmentCRTTube`) — curved glass

Most complex shader. Steps:

1. **Convert to centered coordinates**: `cc = texCoord * 2 - 1` → range [-1, 1]
2. **Barrel distortion**: `curved = cc * (1 + 0.028 * dot(cc, cc))` — pushes UV outward toward edges, creating the characteristic bulge of a curved CRT face. The 0.028 coefficient was tuned by eye.
3. **Rounded-corner SDF**: `faceSDF(curved, radius=0.08)` computes the signed distance to a rounded rectangle with 8% corner radius. `sd < 0` = inside the tube face; `sd >= 0` = in the black mask/bezel.

**Inside the tube face (sd < 0):**
- Apply `crtShade()` on `uv = curved * 0.5 + 0.5` (distorted UV)
- Soft antialiased edge: `1 - smoothstep(-0.012, 0.0, sd)` fades out the picture right at the border
- Vignette: `1 - 0.22 * dot(cc, cc)` — gentle radial darkening toward corners
- Dither + output

**In the black mask (sd >= 0):**
- Compute depth cues for the sunken recess:
  - `rimDist = -faceSDF(cc, 0.30)` — distance from the outer rim of the bezel recess (0 at the lip, positive inward). Used to darken under the case lip.
  - `lipShadow = smoothstep(-0.06, 0.30, rimDist)` — dark near the outer rim (under the plastic case lip), bright toward the face edge
  - `topShadow = mix(0.62, 1.0, smoothstep(-1.15, -0.25, cc.y))` — top of the recess is in shadow (light comes from above)
  - Base color: `float3(0.025) * lipShadow * topShadow` — dark grey with shading

If `reflection < 0.5`, output base color directly (reflection disabled).

**Reflection computation:**
1. Compute SDF gradient numerically (central differences with ε = 0.002) → surface normal `n`
2. Project to the edge: `edgePoint = curved - (sd + 0.05) * n` — move from the current mask point to just inside the glass
3. Convert to UV: `uvr = clamp(edgePoint * 0.5 + 0.5, 0, 1)`
4. Sample a strip of picture adjacent to this mask point: a 9×3 weighted kernel along the tangent direction (`t = float2(n.y, -n.x)`) with Gaussian weights, spread widening with depth (`spread = 1 + sd * 6`)
5. Apply picture controls to the reflection sample
6. Bloom boost: `refl += refl * refl * 0.35` (soft knee)
7. Distance falloff: `fade = exp(-sd * 5.5)` — reflection strongest right at the face edge, dying off exponentially
8. Combine: `base + refl * fade * 0.34 * lipShadow_blend * topShadow`

**Why not true mirror reflection?** True mirroring (`curved - 2*sd*n`) pulls samples from deeper inside the picture as `sd` grows. Near corners, this pulls from wrong-neighborhood content — content that is spatially far from the mask point's adjacent picture area. The edge-projection approach (`edgePoint = curved - (sd + 0.05) * n`) always samples the picture content directly adjacent to the mask point, so the glow tracks the local picture content correctly along the entire edge.

**Dithering.** The `dither()` function adds `(hash(pixelPos) - 0.5) / 255` to every output pixel before the framebuffer quantizes to 8-bit per channel. This breaks up smooth gradient banding — visible as concentric rings in the vignette and in the reflection falloff when brightness is raised or contrast lowered.

### Signal simulation (`compositeSample`)

Called from `crtShade()` when `signal > 0.5`. Works in YIQ color space.

**Luma softening**: 5-tap Gaussian horizontal blur with tap spacing `lumaSoft` (0.55 for Composite, 0.85 for RF — wider on RF means individual C64 pixels melt together). Gaussian weights: `exp(-0.55 * k²)`.

**Ghosting**: adds a faint copy displaced +5 texels to the right, mixed at `ghostAmount` (0.035 Composite, 0.07 RF). Simulates impedance mismatch reflections on a long cable.

**Chroma smear**: asymmetric horizontal average of YIQ chroma (I and Q) with 9 taps from -2 through +6, weighted around a +0.7-texel delay. This models color arriving late relative to luma and bleeding well beyond sharp edges as composite bandwidth collapses. Step spacing is 1.35 texels for Composite and 1.85 for RF; falloff is 0.20/0.16 respectively.

**Dot crawl**: on horizontal color transitions, the comb filter fails and subcarrier bleeds into luma as a checkerboard pattern. Simulated by: compute the chroma edge strength (`length(yiqR.yz - yiqL.yz)`), multiply by a checkerboard factor (`(x + y) % 2 == 0 ? +1 : -1`), and add to luma. Strength: 0.12 Composite, 0.18 RF.

**RF-only artifacts**:
- Snow: animated per-pixel luma noise via `hash21(pixelPos + fract(time) * float2(731, 447))` at 0.10 amplitude
- Interference bar: a single bright line drifting downward, `bandPos = fract(time * (8.0 / 60.0))`, at 0.05 amplitude. Eight complete sweeps divide the renderer's 60-second time loop exactly, so the line never resets before reaching the bottom.
- Per-scanline horizontal jitter: `jitter = (r - 0.5) * 0.14 + step(0.985, r) * 0.5` — most lines jitter slightly, occasional lines slip by half a texel. Applied to `uv.x` before all sampling.
- Chroma noise: 2D noise vector added to IQ at 0.03 amplitude

### CRT screen color

`applyPhosphorColor()` runs only in `fragmentCRT` and `fragmentCRTTube`, after monitor picture controls have decoded/adjusted the color signal. Color returns RGB unchanged. Amber, Green and Black & White convert adjusted RGB to luminance (`dot(c, float3(0.299, 0.587, 0.114))`) and apply phosphor color. Amber is intensity-dependent rather than a fixed tint: `smoothstep(0.08, 0.82, glow)` blends dark brown/orange `(0.82, 0.34, 0.01)` toward bright golden yellow `(1.0, 0.76, 0.06)`, matching real examples whose hue shifts as emission rises. At neutral controls, the exact black level introduced by brightness/contrast is removed so true black remains RGB zero. In Amber/Green, brightness above neutral progressively introduces up to an 18% phosphor-colored raster floor; low contrast can add 7%, while high contrast suppresses that floor by up to 65%. This reproduces a real monochrome tube whose "black" starts glowing when driven, without making neutral black permanently tinted. Signal noise above black remains visible. Amber/Green also add a nonlinear highlight boost and raise CRT horizontal bloom from 0.25 to 0.38. Applying the conversion after `applyPicture()` keeps highlight behavior natural and ensures the tube-mask reflection receives the same phosphor color as the face.

Amber also uses real temporal persistence. `MetalFrameRenderer` stores the previous 12 indexed source frames in an R8Uint 2D-array texture (~240 ms at PAL 50 fps). Initial emission is sampled nearest-neighbor from each frame's palette index, so every C64 source pixel starts at exactly one of the 16 palette-derived amber luminances — history never invents spatial gradient shades. The decay itself is analog: CPU uniforms include the continuously advancing fractional frame age since the latest source upload, and the shader applies `exp(-(integerAge + fractionalAge) * 0.16)` without requantizing the result. Moving objects retain blocky C64 geometry while their golden trails fade smoothly in time; CRT bloom/scanline optics soften the emitted light afterward. A source-frame gap over 500 ms resets history so a disconnected/changed stream cannot ghost into the next session. Green, Black & White, Color, Sharp and Smooth do not use this history.

The settings are per-device and backward-compatible: `Snapshot.crtScreenColor` and `Snapshot.crtDirtyGlass` are optional when decoding, so existing saved display JSON defaults to Color + clean glass without losing older settings.

### Dirty CRT glass

`crtDirtyGlass` is a per-device, backward-compatible Boolean available only when `.crt` or `.crtTube` is selected. Sharp/Smooth ignore it completely. The effect is procedural and static in destination screen space, so contamination stays attached to the physical glass while video moves underneath:

- Two-scale value noise creates uneven dust/nicotine film.
- Three rotated elliptical masks create fingerprint/palm smears and a dried cleaning streak.
- Three mineral/moisture spots combine cloudy centers with sharp pale rings.
- A six-pixel cell hash places dense fine dust; a separate sparse ten-pixel grid adds isolated 1–2 pixel dark brown/olive grime flecks. Both are fixed without textures.
- `Resources/dirty-glass-mask.png` is a generated 1536×1024 photographic RGBA material mask containing realistic corner lint, fibers and granular buildup. The shader center-crops it to 4:3, confines it to small 22%×11% extreme-corner falloffs, caps mask opacity at 32%, and attenuates residue elsewhere to 2%. A transparent 1×1 fallback keeps procedural layers working if the resource is missing.
- `dirtyGlassUV()` refracts the sampled picture around the moisture spots before CRT/phosphor rendering.
- `applyDirtyGlass()` then lowers contrast/transmission, warms the image, adds a tiny ambient reflection over black, darkens dust particles, and highlights dried rings.

The overlay runs after phosphor coloring/vignette, while refraction runs before `crtShade()`. This physically separates distortion of the underlying image from contamination on top of the emitted light. The same pipeline is used by filtered screenshots.

### Screenshot capture

"Save Screenshot…" (toolbar camera button, context menu, ⇧⌘S) captures the **actual filtered GPU output**: selected palette, monitor controls, CRT scanlines/tube curvature, Composite/RF artifacts, reflection, and CRT screen color.

`requestFilteredScreenshot()` stores a completion consumed by the next `draw(in:)`. That draw encodes a second pass with the same pipeline, uniforms and source textures into a reusable shared `.bgra8Unorm` offscreen texture sized exactly like the live drawable (destination pixel size matters for scanlines/phosphor mask). A command-buffer completion handler reads the finished texture into a BGRA `CGImage` and returns on the main queue.

`DeviceSession.captureFrame` is completion-based because capture has one-frame GPU latency. `VideoView.makeNSView` assigns it with a weak renderer reference. `saveScreenshot()` waits for the image, presents `NSSavePanel`, encodes via `NSBitmapImageRep`, and reports success/failure through the existing transfer banner.

### `applyPicture()`

Applied to every output in every filter mode:
1. Contrast: `(c - 0.5) * mix(0.4, 1.6, contrast) + 0.5`
2. Brightness: piecewise offset around neutral — lower half reaches -0.35; upper half reaches +0.65 for strong CRT overdrive
3. Convert to YIQ
4. Tint: rotate the IQ plane by `(tint - 0.5) * 1.0` radians (~±28 degrees)
5. Saturation: 0...0.5 maps normally from 0× (greyscale) to 1× (neutral); 0.5...1 ramps aggressively from 1× to 4× chroma
6. Convert back to RGB, clamp to [0, 1]

All controls remain neutral at 0.5. This models what a real composite monitor's pots did: contrast and brightness operate in signal space; color (saturation) and tint rotate the chroma plane. The expanded upper ranges deliberately allow washed-out brightness and chroma clipping/overdrive beyond a calibrated monitor.

---

## 8. Assembly64 Integration

### What it is

Assembly64 (hackerswithstyle.se/leet) is an aggregated online library of C64 software: games, demos, music, tools, from sources including CSDB, GameBase64, HVSC (High Voltage SID Collection), OneLoad64, tape archives, and others. The API is documented at `hackerswithstyle.se/leet/swagger-ui/index.html`.

### Client-ID requirement

Every request must include `client-id: assembly64` in the HTTP header. Without it, the server returns HTTP 200 with JSON `{"errorCode": 464}`. Note: this is a 200 response, not a 401 or 403.

### Error-in-200 envelope

The API has a non-standard error reporting convention: some errors come back as HTTP 200 with a small JSON body `{"errorCode": N}`. The client handles this in `getData()`:
```swift
if data.count < 200,
   let error = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
    throw ClientError.apiError(error.errorCode)
}
```
The `< 200` byte threshold avoids accidentally treating a small valid JSON response as an error. Known error codes: 463 = bad AQL query syntax, 464 = invalid/missing client-id.

### AQL query syntax

AQL (Assembly Query Language) uses space-separated `key:value` terms:
- `name:turrican` — name contains "turrican"
- `subcat:games` — filter to category named "games"
- `repo:csdb type:d64 date:1987 rating:>=7 latest:1year` — discovery facets
- `sort:name order:asc` — sort results

**Critical gotcha:** multi-word values MUST be quoted. `name:last ninja` is parsed as `name:last` followed by stray term `ninja`, which the parser rejects with error 463. The fix:
```swift
let name = text.contains(" ") ? "\"\(text)\"" : text
var query = "name:\(name) sort:name order:asc"
```

This bug manifested as searches for single-word names working fine and multi-word searches always failing with "Assembly64 rejected the search query."

### Discovery filters and presets

`Assembly64Client.presets()` loads `/search/aql/presets` when the window opens. Repository, type, year, recency, sort and order options therefore follow the service instead of being duplicated as app constants; minimum rating is the documented 1–10 range.

`Assembly64SearchFilters` is Codable and captures all facets. Searches may omit a name when category or at least one facet is active, enabling "latest high-rated demos" and similar discovery queries. Named searches persist the exact text, category ID and filter snapshot.

### Favorites, history and metadata

`Assembly64LibraryStore` owns local library state:
- Favorites are result snapshots keyed by the composite `category:itemID`, avoiding collisions between repositories.
- Selecting a result moves it to the front of a deduplicated 30-item recent list.
- Saved searches include every facet and can be reapplied from the toolbar.
- Metadata from `/metadata/{id}/{category}` is cached for 24 hours (maximum 100 entries) and may provide source links and screenshot URLs.
- The last disk action is remembered per item/file and shown as quiet history beside the file size. It does not change button styling and Stream64 never auto-mounts or auto-runs merely because an action was remembered.

The metadata endpoint is optional in practice: many entries return only a name. For categories advertised as `type == "csdb"`, Stream64 falls back to CSDB's release webservice for a screenshot and canonical source link. Missing previews/source links remain a normal empty capability, not an error and do not prevent file loading.

### Search → entries → download flow

1. **Search**: `GET /search/aql/{offset}/{limit}?query=...` → `[SearchResult]` (`pageSize` = 200 per page; see "Search pagination" below for what happens past the first page)
2. **Entries**: when user selects a result, `GET /search/entries/{itemID}/{categoryID}` → `EntriesResponse { contentEntry: [FileEntry] }`. An item can have multiple files (disk side A, disk side B, different versions, etc.)
3. **Download**: when user clicks an action, `GET /search/bin/{itemID}/{categoryID}/{fileID}` → raw `Data`. The data goes straight from the HTTP response body to `DeviceSession.loadData()` — never touches the filesystem.
4. **Archive**: "Save ZIP…" calls `GET /search/zip/{itemID}/{categoryID}` and writes the complete entry to a user-selected local URL. "Inspect ZIP…" downloads once, validates the central directory with `Assembly64ArchiveInspector`, lists safe members, and can feed an individually extracted supported file into `DeviceSession.loadData()`.

Remembered actions are only persisted after `DeviceSession.loadData()` returns a non-nil `LoadOutcome`; a successful download followed by a failed Ultimate upload never becomes the suggested action.

### Search pagination (Load More)

The API has no total-count field — the only way to know whether a query has more results is that a page comes back exactly full (`count == pageSize`). `Assembly64View` tracks this with `hasMoreResults: Bool`, set after every page fetch (initial search or "Load More") to `found.count == Self.pageSize`. A short page, or an empty one, is the only reliable end-of-results signal, so it's treated as definitive rather than probabilistic.

`runSearch()` (fired on Enter, category change, etc.) always starts a fresh query at `offset: 0` and replaces `results` entirely; it also stashes the built AQL query string in `loadedQuery`. `loadMoreResults()` (bound to the status bar's "Load More" button, shown only while `hasMoreResults` and not already loading) re-issues the *same* `loadedQuery` at `offset: results.count` and appends. Keying the offset off `results.count` rather than a separately tracked counter is safe only because results are exclusively grown by appending same-query pages — a `runSearch()` always clears them first, so there's no path where `results.count` could drift from "how many rows of this query have been fetched so far."

A failed "Load More" (network hiccup mid-scroll) leaves the existing results on screen and reports the failure via `loadStatus` rather than clobbering `searchState` to `.failed` — losing 200 already-loaded rows over a transient error on page 2 would be a worse experience than just letting the user retry the button.

### Mount & Run boot chain

When the user clicks "Mount & Run" on a disk image:
1. `Assembly64View.load()` downloads the data
2. Calls `session.loadData(data, filename:, mountBehavior: .mountAndRun)`
3. `loadData()` dispatches on `.mountAndRun`:
   - Upload and mount via `client.mountDisk()`
   - `flushPendingKeys()` — clear any stale input
   - `client.reset()` — hardware reset
   - `Task.sleep(3 s)` — wait for BASIC boot
   - `typeKeys("load\"*\",8,1\r")` — BASIC load command
   - `Task.sleep(1 s)` — wait for load to start
   - `typeKeys("run\r")` — start program

This is fully automatic: the user clicks once, the disk boots.

### Category picker

Categories and AQL presets are loaded concurrently once on `.task` when the window opens. Categories are grouped by `groupingName`; selected categories add `subcat:<categoryName>`. The Filters menu uses the preset response for repository, file type, year, recency, sort and order values, with explicit Apply/Clear actions so changing several facets does not fire several intermediate API requests.

---

## 9. Multi-Device

### SessionManager

`SessionManager` is a `@MainActor final class ObservableObject` defined in `ContentView.swift`, instantiated as `@StateObject` in `Stream64App`, and passed down via `.environmentObject()`. It holds `[UUID: DeviceSession]` — one session per device.

`session(for:settings:)` returns the existing session if the device matches (same UUID and same device struct), or creates a new one. This means editing a device's configuration (address, port) recreates its session.

### Audio policy

At most one device is audible. `muteAll(except:)` sets `audioReceiver.muted` on all sessions except the specified UUID. Called:
- On `ContentView.onAppear`
- On `DeviceStore.selectedDeviceID` change
- On `showAllScreens` toggle
- On each `ViewerTile.onAppear` (for sessions that connect after the policy last ran)

Per-tile mute control was tried earlier but left orphaned unmuted streams after view teardown. Centralized muting in `SessionManager` is the correct approach.

### Grid view

`MultiViewerGrid` uses `LazyVGrid` with `GridItem(.adaptive(minimum: 420, maximum: 900))`. Each tile is a `ViewerTile` with a forced 4:3 aspect ratio.

Clicking a tile selects it (changes `deviceStore.selectedDeviceID` → triggers audio policy).  
Double-clicking a tile selects it and switches `showAllScreens = false` (returns to single view).

Each tile has its own `VideoView` with its own `MetalFrameRenderer`, its own `VideoReceiver` and `AudioReceiver`. Independent UDP ports enable true simultaneous streaming.

### Port assignment

Each device has its own `videoPort` and `audioPort` (local UDP ports on the Mac). The device is told to stream to `<primaryIPv4>:<videoPort>` and `<primaryIPv4>:<audioPort>`. Devices can never share a port.

`UltimateDevice.makeDefault(avoiding:)` walks upward from port 11000 in steps of 2, skipping any pair used by existing devices. Standard assignments for the three configured devices: 11000/11001, 11002/11003, 11004/11005.

### Per-device rendering settings

Every visual aspect of how a stream is rendered is per-device: filter mode, scaling, palette, input signal, bezel style/visibility/reflection, and picture controls. The `DisplaySettings.shared(for:)` singleton ensures each device has its own instance, and all control surfaces for that device share it.

---

## 10. Known Bugs Fixed and Hard-Won Lessons

This section documents every non-obvious decision and every bug that required real debugging to understand. These decisions look like they could be "simplified" — don't.

### SessionManager must be @StateObject at the app level

**Symptom:** Duplicate sessions (two VideoReceivers, two audio engines), black screens, doubled or phantom audio, sessions appearing and disappearing with each interaction.

**Root cause:** Any `@ObservedObject` publish in `ContentView` (fps updates, connection state changes, anything) causes SwiftUI to re-evaluate `ContentView`'s `body`. In SwiftUI, view struct properties are recreated on re-evaluation. A `let sessionManager = SessionManager()` in `ContentView` would create a new `SessionManager` (and new sessions) every time `body` ran.

**Fix:** `@StateObject` in `Stream64App`. The `App` struct is never recreated during an app's lifetime. The three core objects (`DeviceStore`, `AppSettings`, `SessionManager`) and `Assembly64LibraryStore` are all app-level `@StateObject`s.

### Triple-buffered frame textures

**Symptom:** Picture tearing in CRT Composite and RF filter modes. Not visible in Sharp mode.

**Root cause:** `MTLTexture.replace()` is a CPU write. If the GPU is still executing a fragment shader that reads the texture (slow in CRT modes), and the CPU overwrites it, the GPU reads a partially written texture — tearing.

**Fix:** Three textures in a ring. `currentTextureIndex = (currentTextureIndex + 1) % 3` before each upload ensures the upload target is never the texture bound to any in-flight command buffer.

**Why it only manifested with CRT modes:** Sharp mode fragment shaders complete before the next frame arrives. CRT modes with compositeSample (many bilinear samples, YIQ math, noise) take long enough that the next frame can arrive while the GPU is still reading the previous texture.

### FPS publishes only on ≥0.5 changes

**Symptom:** Right-click context menus collapsed (submenus closed themselves) while the user was navigating them. Happened once per second.

**Root cause:** `onStats` fires approximately every second. If `fps` is `@Published` and updates every second, every `@ObservedObject` subscriber to the session re-renders. `StreamContextMenu` observes the session. Re-rendering a SwiftUI context menu while it's open causes it to rebuild and collapse.

**Fix:** `if abs(fps - self.fps) >= 0.5 { self.fps = fps }`. A steady 50 fps stream (reporting 49.8/50.1/49.9) never crosses 0.5 delta, so `fps` only publishes when something genuinely changes.

### Context menus snapshot state rather than observe it

**Symptom:** Same as above — menus collapsing during navigation.

**Root cause:** `@ObservedObject var session` in `StreamContextMenu` subscribes the menu to all session publishes. Even with the fps threshold fix, other publishes (connection state, transferStatus) could rebuild the menu at inopportune moments.

**Fix:** `let session: DeviceSession` (not `@ObservedObject`). Menu items read values at menu-open time. Writes go through `bind(_:)` helper bindings that write-only. The menu won't update while open, but menus are opened momentarily and the state read at open time is accurate enough.

### VideoView observes DisplaySettings directly

**Symptom:** Filter mode changed in toolbar → picture didn't update until some other event caused the view to re-render.

**Root cause:** `updateNSView` only runs when `VideoView` re-renders. `ViewerPane` might not re-render when `DisplaySettings` changes (it observes `session` and `display` but may not receive a timely update if the change comes from the Settings window, which is a different view tree).

**Fix:** `@ObservedObject var display: DisplaySettings` in `VideoView` (in addition to `@ObservedObject var session`). `VideoView` now re-renders directly on any `DisplaySettings` change, regardless of whether its host view does.

### Firmware 3.14 "Network Host Resolve Error" / wedged streaming stack

**Symptom:** `startStreaming()` throws with message containing "Network Host Resolve Error". Device's web UI works fine. This error can appear transiently (resolves with one retry) or persistently (requires device reboot).

**Root cause:** Firmware 3.14 bug in the streaming stack. The stack appears to wedge and reject all stream destinations (even plain IP addresses) while the REST API continues working normally. The stack does not self-recover; only a full device reboot fixes it.

**Handling:**
1. Transient case: caught in `connect()`, retried once after 1 second
2. Persistent case: surfaces as `.error(...)` with a "Reboot Device & Retry" button in the error panel
3. The error message explicitly names the cause ("The Ultimate's network stack appears stuck") so the user knows to reboot the device, not their Mac

### Cold-boot streaming: stop/start cycle

**Symptom:** After cold power-on (device was completely off), `startStreaming()` returns HTTP 200 but no packets arrive. The device acknowledges the start request but doesn't send anything.

**Root cause:** Firmware behavior — the streaming generator needs to be kicked. Newer C64 Ultimate firmware also requires a short teardown interval after stop.

**Fix:** `startStreaming()` stops all requested streams, waits one second once, then starts them. The stop calls use `try?` (the stream may not be running). This exact sequence was verified live on C64 Ultimate 1.1.0 after immediate stop/start repeatedly produced the misleading network-stack error.

### CoreAudio error 35 on rapid reconnect

**Symptom:** `AVAudioEngine.start()` throws with error code 35 (`kAudioHardwareIllegalOperationError`) when reconnecting a device that was just disconnected. Showed as an audio failure banner over a working picture.

**Root cause:** CoreAudio refuses to start an engine that was stopped very recently. The audio hardware needs time to release.

**Fix 1:** `Thread.sleep(0.25)` + one retry inside `AudioReceiver.start()`.  
**Fix 2:** The `connecting: Bool` reentrancy guard in `DeviceSession.connect()` prevents concurrent connect attempts that would race on the audio engine.  
**Fix 3:** `recoverAudioQuietly()` makes audio startup non-fatal — failure shows a banner but doesn't block the connection state machine.

### Occluded windows stop MTKView's display link

**Symptom:** In the multi-device grid, when a window (e.g. Settings) was placed over the grid, the obscured tiles stopped updating. The streams were still flowing but frames weren't being presented.

**Root cause:** macOS pauses `MTKView`'s `CADisplayLink` when the window is not visible on screen (occluded). `enableSetNeedsDisplay = false` and `isPaused = false` do not override this.

**Fix:** `KeyCapturingMTKView` observes `NSWindow.didChangeOcclusionStateNotification`. When the window loses visibility, a `Timer` at 1/50 s intervals calls `draw()` manually. When visibility is restored, the timer is invalidated and the display link resumes naturally.

### One audible device enforced centrally

**Symptom:** After navigating between devices, multiple devices would be audible simultaneously. After view teardown (switching from grid to single view), the previously audible device in the grid would remain unmuted.

**Root cause:** Per-tile mute logic scattered across view lifecycle events. Views being torn down didn't reliably unmute/mute.

**Fix:** `SessionManager.muteAll(except:)` is the single point of truth. Called from `ContentView` on selection changes and mode changes. Called from `ViewerTile.onAppear` to handle sessions that connect after the policy ran.

### fetchInfo must use /v1/info, not /v1/version

**Symptom:** Every device showed as "Unreachable" even when fully online and streaming.

**Root cause:** Original code used `/v1/version` which returns `{"version":"0.1"}`. `DeviceInfo` decodes `product`, `firmwareVersion`, `hostname`, `uniqueId` — none of which are in the version response. Decoding failed (throws), `fetchInfo()` threw, `probeReachability()` returned nil, `connect()` set state to `.unreachable`.

**Fix:** Use `/v1/info` which returns the full device info object. Committed in 3bf18e9.

### Independent video+audio pickup check

**Symptom:** After app restart while device was still streaming, audio would be silent (no sound) even though video was fine.

**Root cause:** Original pickup check was `if videoLive && audioLive { break }` — short-circuited once video was live. If video arrived first and audio hadn't been seen yet, the loop broke early without checking audio. Then `startStreaming(video: !videoLive, audio: settings.audioEnabled && !audioLive)` was called with `audio: true` (since audioLive was false) but `video: false` — only audio was started. But the streaming stack was in the "video already running, audio never started" state and the audio start sometimes silently failed.

**Fix:** Check video and audio independently: `if videoLive && (audioLive || !settings.audioEnabled) { break }`. If only video is live after 600 ms, audio still gets a fresh start/start cycle.

### Stream pickup must compare against a per-connect baseline

**Symptom:** Device was reachable and the session showed Online, but reconnecting did not initiate video/audio. Manually calling `PUT /v1/streams/video:start?ip=172.16.10.15:11000` immediately worked.

**Root cause:** `VideoReceiver` and `AudioReceiver` are session-lifetime objects. Their `packetsReceived` counters deliberately survive listener restarts. The pickup check used `packetsReceived > 0`, so once a receiver had ever seen traffic, every later reconnect could misclassify that stale count as a currently arriving stream and skip `stream:start`.

**Fix:** Snapshot both counters immediately after opening the listeners and require them to increase during the 600 ms pickup window. A new explicit `connect()` also clears `streamsStoppedByUser`, `fps`, and `isStreaming`.

`UltimateAPIClient.perform()` additionally decodes JSON responses containing an `errors` array and throws when it is non-empty, even for HTTP 2xx. Current C64 Ultimate firmware can report command-level failure in this envelope; accepting status code alone would leave the UI Online with no stream.

### Multiple Stream64 processes split UDP delivery

**Symptom:** A freshly restarted window reported "No video arriving" while the device was online and another Stream64 process appeared healthy or remained hidden.

**Root cause:** The Network listeners enable local endpoint reuse. Two processes can therefore bind 11000/11001 simultaneously; macOS may deliver the C64U packets to the older process while the new process sees none. This commonly happened when an earlier `swift run` test instance was left alive and another was launched from Terminal.

**Fix:** `SingleInstanceLock` is acquired before window creation. A second process activates the PID recorded by the lock owner and terminates immediately. Verified by launching `swift run` twice: the second command exited in ~1 second, exactly one Stream64 process remained, and the original continued receiving video/audio.

---

## 11. Device Specifics

Three devices are configured. All use the default API port 80 with no password.

### C64U Starlight
- **Name:** C64U Starlight
- **Address:** 172.16.10.51
- **Video port (local):** 11000
- **Audio port (local):** 11001
- **UUID:** AD4810FB-2DF6-48EB-9BFA-F9DCBE8B83FD
- **Notes:** Primary development device; running C64 Ultimate firmware 1.1.0 as of 2026-07-20

### Ultimate Elite 2
- **Name:** Ultimate Elite 2
- **Address:** 172.16.10.64
- **Video port (local):** 11002
- **Audio port (local):** 11003
- **UUID:** C0CD8EEF-A109-44AF-B994-112A88D4F5EB

### C64U Founders
- **Name:** C64U Founders
- **Address:** 172.16.10.65
- **Video port (local):** 11004
- **Audio port (local):** 11005
- **UUID:** 3902FBF8-5E97-4026-8CB6-16D96F06409F

### Firmware notes

The Ultimate 64/Elite devices were tested against the legacy 3.14 firmware line. C64U Starlight now reports the newer C64 Ultimate firmware 1.1.0. The stream command remains `PUT /v1/streams/{video|audio}:start?ip=<destination>:<port>` on both; this was verified live against 1.1.0 with `172.16.10.15:11000/11001`.

Known firmware quirks:
- **Misleading network-stack error** (see section 10): stream start can report "Network Host Resolve Error" for a literal IP when issued too quickly after stop. Stop → wait 1 s → start fixes this on C64 Ultimate 1.1.0. A genuinely persistent failure after settled retries may still require reboot; the app retains Reboot Device & Retry for that case.
- **Cold-boot no-packets**: After a complete power cycle (not just reboot), the device accepts stream-start commands but sends no packets until a stop/start cycle is performed.
- **No keyboard endpoint**: Verified absent. Keyboard injection must use DMA memory access (`machine:readmem`/`machine:writemem`).
- **Stream auto-stop on reboot**: Device-side streams stop when the device reboots. The app re-arms streams automatically after detecting the device is back online.

---

## 12. Build & Run

### Building

Stream64 is a Swift Package — no Xcode project file needed.

```sh
cd ~/UltimateViewer

# Command line:
swift run

# Unit tests (Assembly64 query/identity/persistence/ZIP safety):
swift test

# With debug logging:
UV_DEBUG=1 swift run

# Or open in Xcode:
open .
# Xcode will detect the Package.swift and create the Stream64 scheme automatically
```

**Requirements:** macOS 14+, Xcode 15+ (Swift 5.9), Apple Silicon or Intel with a Metal-capable GPU. The package target declares `.macOS(.v14)`. Both arm64 and x86_64 release builds are supported. SwiftPM resolves ZIPFoundation 0.9.20 for safe in-memory Assembly64 archive inspection; keep `Package.resolved` committed.

### Ad-hoc release packaging

`VERSION=1.0.0 BUILD_NUMBER=1 ARCH=<arm64|x86_64> ./Scripts/build-release.sh` performs the complete local distribution pipeline. `ARCH` defaults to arm64; artifacts are isolated under `dist/<architecture>/`.

1. Cross-compiles the optimized SwiftPM executable for `<architecture>-apple-macosx14.0` and verifies the Mach-O architecture with `lipo`.
2. Creates `dist/<architecture>/Stream64.app` with `Packaging/Info.plist`, GPL license, privacy manifest and `dirty-glass-mask.png` under standard `Contents/Resources`.
3. Replaces version/build placeholders using PlistBuddy.
4. Applies an ad-hoc signature (`codesign --sign -`) and verifies the app with `--deep --strict`.
5. Creates a ZIP and drag-to-Applications UDZO DMG.
6. Ad-hoc signs and verifies the DMG with `hdiutil verify`.
7. Writes SHA-256 checksums for both distributable files.

`MetalFrameRenderer` first looks for its dirt texture through `Bundle.main` (packaged app) and only evaluates `Bundle.module` as a fallback under `swift run`. Do not copy SwiftPM resource bundles into the `.app` root: codesign rejects those as unsealed root contents.

Ad-hoc signing proves bundle integrity but does not establish an Apple-trusted developer identity and cannot be notarized. Downloaded copies require Control-click → Open or approval under Privacy & Security on first launch. `dist/` is ignored by Git.

### Running

Launch the built app. It activates as a regular foreground app with a Dock icon (the `NSApplication.shared.setActivationPolicy(.regular)` call in `init()` handles this for `swift run` without a bundle).

Persistent state:
- Devices list: `~/Library/Application Support/Stream64/devices.json`
- Per-device display settings: `UserDefaults` keys `displaySettings.<UUID>`
- App settings: `UserDefaults` (standard keys like `audioEnabled`, `volume`, etc.)
- Selected device: `UserDefaults` key `selectedDeviceID`
- Assembly64 user library: `~/Library/Application Support/Stream64/assembly64-library.json`
- Regenerable Assembly64/CSDB metadata: `~/Library/Caches/Stream64/assembly64-metadata.json`

### Pushing to GitHub

The repo is at `github.com/mbosschaart/Stream64`; `origin` uses HTTPS. Both `mbosschaart` and the work account may be authenticated in GitHub CLI, but this project should remain on the personal account:

```sh
gh auth switch -u mbosschaart
gh auth status
```

If `git push` reports "Repository not found", verify the active CLI/keychain account before changing any repository configuration.

The `.gitignore` excludes `.build/`, `.DS_Store`, `*.xcodeproj`, `.swiftpm/`, and generated `dist/` release artifacts. `Package.resolved`, packaging scripts/metadata, tests and source resources are tracked. Device and Assembly64 user-state files live under Application Support, outside the repository.

---

## 13. What Needs Work / Future Ideas

### Confirmed limitations (not bugs, inherent constraints)

- **Games that scan the keyboard matrix** cannot receive injected keystrokes. This is a fundamental limitation of the KERNAL buffer injection approach. The firmware has no hardware matrix injection endpoint. A future firmware version could add this; the app would need a new API call.
- **Stream duration auto-stop**: When `streamDurationSeconds > 0`, the device stops streaming after the configured time. The user must manually click "Restart Streams". There is no push notification from the device — detecting expiry requires noticing the watchdog fires (fps drops to 0), which the app already does. The watchdog recovery path could be smarter here.
- **No audio output device selection**: Audio always goes to the system default output device. `AVAudioEngine` could be extended to support device selection, but the UI has no surface for it.

### Known issues not yet addressed

- **Integer scaling in fullscreen**: In integer scale mode at large screen sizes, the picture can appear very small if no integer multiple of 272 fits the screen nicely. A "largest integer that fills at least 80%" heuristic might be better.
- **SID file playback UI**: There's no "stop SID" command in the app (no such API endpoint exists). The user has to reset the machine.

### Things discussed but not built

- **Recording**: Capturing a session to video. Complex: would need CoreMedia encoding, significant CPU overhead for encoding concurrent with rendering.
- **Full-screen per-device cursor**: In fullscreen with multiple devices, showing a mini stream label when hovering over the channel-switch arrows.
- **mDNS discovery**: Auto-discovering Ultimate devices on the local network via Bonjour/mDNS rather than requiring manual IP entry. The Ultimate firmware may advertise via mDNS (untested).
- **Keyboard shortcuts per device**: In single view, macOS keyboard shortcuts (⌘R for Reset, etc.) conflict with the viewer sending ⌘ as a modifier to the C64. Currently ⌘ key presses are swallowed (`if event.modifierFlags.contains(.command) { return nil }`). A separate shortcut layer would be needed.
- **Pixel shader customization**: Exposing the barrel distortion coefficient, scanline strength, phosphor mask intensity, and bloom amount as per-device settings rather than hardcoded shader constants.
- **WebSocket streaming**: The Ultimate firmware may eventually support WebSocket-based streaming as an alternative to UDP. No current plans to implement.

### Recently implemented (2026-07-20)

The following roadmap items have since been built:

- **Automatic reconnect** — see the new subsection in §5, "Mid-session disconnect detection & automatic reconnect."
- **Screenshot export** — see the new subsection in §7, "Screenshot capture."
- **Assembly64 pagination** — see the updated §8, "Search pagination (Load More)."
- **Sidebar drag-to-reorder** — `DeviceStore.move(fromOffsets:toOffset:)` plus `.onMove` on the sidebar's `ForEach`. Purely cosmetic list ordering, persisted the same way as the rest of the device list (`devices.json`); doesn't touch ports, UUIDs, or sessions.
- **Enhanced Assembly64 discovery (roadmap feature 03)** — repository/type/year/rating/recency/sort filters, favorites, recent history, saved searches, metadata previews/source links, complete-entry ZIP download, cancellable selection loading and remembered disk actions.

---

## Appendix: The Ultimate REST API — Complete Usage Reference

All endpoints use `http://<device-host>/v1/...`. Auth via `X-Password: <password>` header when a password is set. No auth = no header.

| Method | Endpoint | Query / Body | Notes |
|---|---|---|---|
| GET | `/v1/info` | — | Returns `{product, firmware_version, hostname, unique_id}`. Use this, not `/v1/version`. |
| PUT | `/v1/machine:reset` | — | C64 hardware reset |
| PUT | `/v1/machine:reboot` | — | Full device reboot (streams stop) |
| PUT | `/v1/machine:pause` | — | Freeze machine clock |
| PUT | `/v1/machine:resume` | — | Resume |
| PUT | `/v1/machine:poweroff` | — | Power off C64 |
| PUT | `/v1/machine:menu_button` | — | Simulates pressing the physical menu button |
| GET | `/v1/machine:readmem` | `address=XXXX&length=N` | Read N bytes from C64 RAM. Address in hex. Returns raw bytes. |
| PUT | `/v1/machine:writemem` | `address=XXXX&data=HHHH…` | Write bytes to C64 RAM. Data as hex string (no separators). |
| PUT | `/v1/streams/video:start` | `ip=host:port[&duration=N]` | Start VIC stream to host:port. Duration in seconds (0 = forever). |
| PUT | `/v1/streams/video:stop` | — | Stop VIC stream |
| PUT | `/v1/streams/audio:start` | `ip=host:port[&duration=N]` | Start SID audio stream |
| PUT | `/v1/streams/audio:stop` | — | Stop audio stream |
| POST | `/v1/runners:run_prg` | Body: raw PRG bytes, `Content-Type: application/octet-stream` | Reset + DMA-load + run |
| POST | `/v1/runners:sidplay` | Body: raw SID bytes, `Content-Type: application/octet-stream` | Play SID tune |
| POST | `/v1/runners:run_crt` | Body: raw CRT bytes, `Content-Type: application/octet-stream` | Run cartridge |
| POST | `/v1/drives/a:mount` | Multipart form-data with `file` part; optional `?type=ext` query | Mount disk image in drive A |

**Keyboard buffer addresses:**
- `$0277` (decimal 631): start of 10-byte KERNAL keyboard buffer
- `$00C6` (decimal 198): pending key count in the buffer
