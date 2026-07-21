# Stream64

A native macOS viewer and remote control for the **Commodore 64 Ultimate** family (C64 Ultimate, Ultimate 64, Ultimate 64 Elite, Ultimate-II+). Stream64 receives the device's live video and audio streams over the network and renders them with Metal — with authentic CRT simulation, complete monitor cases, full keyboard input, drag-and-drop file loading, and simultaneous multi-device viewing.

Designed by Martijn Bosschaart, 2026.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-green)
![Version](https://img.shields.io/badge/version-0.91b-purple)

## Features

- **Live video/audio streaming** — the Ultimate's VIC video stream (384×272 @ ~50 fps PAL) and SID audio (47983 Hz stereo) over UDP, rendered via Metal with low video latency, automatic reconnect/stream re-arm, stop-settle-start firmware recovery, and packet-baseline liveness checks
- **CRT simulation** — luminance-aware scanlines, monitor-specific shadow-mask pitch (1084S 0.42 mm, 1702 0.64 mm), bloom, curved glass, vignette, reflection, selectable Color/Amber/Green/Black & White phosphors, and long analog Amber afterglow sourced from the C64's indexed 16-color history
- **Signal-path simulation** — S-Video (clean), Composite (strong asymmetric chroma bleed, dot crawl, ghosting), or RF (snow, line jitter, interference bar, stronger ghosting — plus matching TV-speaker audio: mono, two-pole bass/treble roll-off, distortion, static, mains hum)
- **Dirty Glass mode** — optional years-of-neglect layer for CRT modes with photographic corner lint, procedural film/dust/dark flecks, separated smudges, droplet-sized mineral residue, subtle refraction, warm haze and contrast loss
- **Monitor cases and bezels** — complete Commodore 1702/1084S cases are drawn in SwiftUI; the bezel is the angled inner plastic lip overlapping the tube glass. The 1702 door reveals **working knobs** (volume, brightness, 4× color overdrive, tint, contrast)
- **Multi-device** — view all machines simultaneously in a grid, each with its own rendering settings; one-click audio switching; ←/→ channel-surfing and five-second pointer auto-hide in fullscreen
- **File loading** — drag a `.prg` or disk image (`.d64/.g64/.d71/.g71/.d81`) onto any stream; hold ⌃ to **Multi Drop** onto every connected machine at once
- **Assembly64 search browser** — search the online C64 library (CSDB, GameBase64, HVSC, OneLoad64, …) with category/repository/type/year/rating/recency filters, pagination, favorites, recents, saved searches, previews/source links, safe ZIP inspection, remembered successful actions, and direct device loading
- **Keyboard input** — type on the C64 from your Mac (KERNAL keyboard-buffer injection over DMA), plus a full on-screen C64 keyboard with PETSCII shift combinations
- **Machine control** — reset, reboot (with automatic stream re-arm), pause/resume, menu button, and power off; CRT Tube shutdown collapses the last frame into a bright line/dot with synchronized voltage-discharge crackle
- **Filtered screenshots** — toolbar camera, context menu, File command or ⇧⌘S saves exactly what Metal renders, including CRT curvature, signal artifacts, phosphor color/afterglow, reflection and dirty glass
- **Single-instance safety** — repeated launches activate the existing app instead of creating competing UDP listeners; closing any viewer fully closes Assembly64/Help/Settings and terminates the process
- **In-app documentation** — Help → Stream64 Help (⌘?)

## Requirements

- macOS 14 (Sonoma) or newer, Apple Silicon or Intel with a Metal-capable GPU
- Ultimate 64/Elite firmware **3.11+**, or C64 Ultimate firmware **1.1+**, on the same network
- UDP path from device to Mac (no firewall blocking the stream ports)

## Building & Running

Stream64 is a Swift Package — no Xcode project needed:

```sh
swift run
```

Or open the folder in Xcode and run the `Stream64` scheme.

### Ad-hoc signed app and DMG

Build distributable `.app`, ZIP and drag-to-Applications DMG packages:

```sh
# Apple Silicon (default)
VERSION=0.91b BUILD_NUMBER=91 ARCH=arm64 ./Scripts/build-release.sh

# Intel
VERSION=0.91b BUILD_NUMBER=91 ARCH=x86_64 ./Scripts/build-release.sh
```

Artifacts are written to `dist/<architecture>/`:

- `Stream64.app`
- `Stream64-<version>-macos-<architecture>.zip`
- `Stream64-<version>-macos-<architecture>.dmg`
- `Stream64-<version>-macos-<architecture>-SHA256.txt`

These are separate thin arm64 and x86_64 builds, not one universal binary.

The bundle is ad-hoc signed and integrity-verified, but not Apple-notarized. \
After downloading it, users must Control-click **Stream64 → Open** the first \
time (or approve it under **System Settings → Privacy & Security**). Never \
disable Gatekeeper globally.

## Quick Start

1. Launch Stream64 and click **Add Device…** (⇧⌘N)
2. Enter the device's IP address or hostname; **Test Connection**; **Add**
3. The viewer connects automatically: it verifies the device over REST, opens local UDP listeners, and asks the device to stream to your Mac

Right-click the picture for stream, machine and display controls. The toolbar additionally provides the on-screen keyboard, Assembly64 browser, screenshots and fullscreen.

---

# Architecture

```
┌───────────-──┐  REST (HTTP)   ┌──-────────────────┐
│              │◀──────────────▶│ UltimateAPIClient │  control plane
│  C64 Ultimate│                └───-───────────────┘
│   (device)   │  UDP video     ┌────────────────-──┐   ┌───────────-────────┐
│              │───────────────▶│  VideoReceiver    │──▶│ MetalFrameRenderer │──▶ screen
│              │  UDP audio     ├─────────────────-─┤   └──────────-─────────┘
│              │───────────────▶│  AudioReceiver    │──▶ AVAudioEngine ──▶ speakers
└─────────-────┘                └─────────────────-─┘
                                        ▲
                               DeviceSession (per device)
                                        ▲
                     SessionManager / SwiftUI views / DisplaySettings
```

Each configured device gets one `DeviceSession` owning its receivers, API client and display settings. Sessions are cached in `SessionManager` and survive view rebuilds. Suggested device defaults allocate distinct UDP port pairs, but manual edits are not collision-validated. `SingleInstanceLock` prevents separate Stream64 processes from competing for the same listeners. `Assembly64LibraryStore` and `Assembly64Cache` separate persistent user intent from regenerable metadata. Health monitoring, reconnect/backoff, screenshot GPU readback and resource lookup operate around the core stream path.

## Source Layout

```
Sources/Stream64/
├── Stream64App.swift          App entry, menu bar, Help/About, window lifecycle
├── Models/
│   ├── UltimateDevice.swift   Device config (address, ports, auto-connect)
│   ├── DeviceStore.swift      Persistence (Application Support/Stream64/devices.json)
│   ├── AppSettings.swift      Global prefs (audio, network, general) — @AppStorage
│   ├── DisplaySettings.swift  Per-device rendering settings, persisted by device UUID
│   ├── Assembly64LibraryStore.swift  Favorites, recents, saved searches/actions
│   ├── Assembly64SearchQuery.swift   Tested AQL query composition
│   └── PETSCII.swift          ASCII/Unicode → PETSCII encoding for keyboard input
├── Services/
│   ├── UltimateAPIClient.swift  REST client for the Ultimate's /v1 API
│   ├── Assembly64Client.swift   Assembly64 search, metadata, archive/download API
│   ├── Assembly64ArchiveInspector.swift  Safe in-memory ZIP inspection/extraction
│   ├── Assembly64Cache.swift    Bounded regenerable metadata/preview cache
│   ├── CSDBPreviewClient.swift  CSDB screenshot/source fallback
│   ├── SingleInstanceLock.swift Process lock preventing duplicate UDP listeners
│   ├── DeviceSession.swift      Connection lifecycle, keyboard queue, file loading
│   ├── VideoReceiver.swift      UDP listener; assembles 4bpp packets into frames
│   └── AudioReceiver.swift      UDP listener; ring buffer → AVAudioSourceNode; RF filter
├── Rendering/
│   └── MetalFrameRenderer.swift Metal + shaders (CRT/signal/phosphor/history/dirt)
├── Resources/
│   └── dirty-glass-mask.png     Photographic RGBA glass-contamination material
└── Views/
    ├── ContentView.swift        Split view, viewer pane, multi-device grid, toolbar
    ├── VideoView.swift          NSViewRepresentable MTKView wrapper + key capture
    ├── StreamContextMenu.swift  Right-click menu (full per-stream control set)
    ├── Assembly64View.swift     Assembly64 search browser window
    ├── MonitorBezelView.swift   1702/1084S bezels; KnobDial rotary control
    ├── OnScreenKeyboardView.swift  Full C64 keyboard layout
    ├── DeviceEditSheet.swift    Add/edit device with connection test
    ├── SettingsView.swift       Preferences window (per-device video tab)
    └── HelpView.swift           In-app documentation window
Tests/Stream64Tests/             AQL/CSDB, persistence/migration, ZIP safety, CRT constants, lock and Metal compile tests
Scripts/build-release.sh         arm64/x86_64 ad-hoc app/ZIP/DMG packaging
Packaging/Info.plist             macOS application-bundle metadata
Package.swift / Package.resolved SwiftPM targets, ZIPFoundation and pinned resolution
LICENSE / CHANGELOG.md           License and release history
```

## The Data Path

### Video

The Ultimate sends the VIC frame as UDP packets: a 12-byte header (sequence, frame number, line number with a last-packet flag, pixels-per-line, lines-per-packet, bits-per-pixel) followed by 4-bit palette indices. `VideoReceiver` assembles lines into a 384×272 byte buffer and hands completed frames to the renderer.

`MetalFrameRenderer` uploads each frame into a **ring of three `r8Uint` textures** (never writing a texture the GPU may still be reading — a CPU `replace()` during a slow fragment shader pass tears the picture) and draws a fullscreen quad. The fragment shader does palette lookup on the GPU from a 16×1 palette texture, so the CPU never touches RGB.

The scaling math targets a **4:3 display aspect** (the C64's pixels are not square; 384×272 ≈ 1.41:1 as raw pixels but a real C64 fills a 4:3 tube). Fit letterboxes, Integer steps in whole multiples of the source height.

### Audio

The audio stream is 16-bit stereo at 47983 Hz (the Ultimate's actual PAL-derived rate), 192 sample pairs per packet. `AudioReceiver` uses a **pull model**: an `AVAudioSourceNode` render callback pulls from a lock-guarded ring buffer. A jitter buffer (default 60 ms, configurable) absorbs network variance; backlog beyond the target is trimmed so latency is bounded and can never ratchet upward — network hiccups produce a brief silence, not permanent delay.

The **RF audio filter** (active when a stream's input signal is RF and a CRT filter is rendering) runs inside the render callback: mono fold, two-pole ~3.3 kHz low-pass, two-pole ~330 Hz high-pass, tanh soft-clip drive, low-passed hiss bed and 50 Hz hum. All per-sample with no allocations on the audio thread.

### Rendering & Shaders

All shaders live as source in `MetalFrameRenderer.swift` and compile whenever a renderer is created (one per active view/tile). XCTest instantiates a renderer to catch Metal-source failures. The pipeline per filter mode:

| Mode | Shader work |
|---|---|
| Sharp | Nearest-neighbor palette lookup |
| Smooth | Manual bilinear blend of palette-expanded texels |
| CRT | `crtShade`: luminance/brightness-dependent scanlines, physical monitor dot pitch, bloom and optional dirty glass |
| CRT Tube | Everything above + barrel distortion, rounded-corner SDF mask, vignette, and mask reflection |

Signal simulation (`compositeSample`) runs before the CRT treatment, in **YIQ space**: gaussian luma soften, wide asymmetric chroma smear (bandwidth collapse), comb-filter dot crawl on chroma edges, displaced-copy ghosting. RF adds animated snow, per-scanline jitter, a drifting interference line, and stronger everything, driven by a frame-counter time uniform.

CRT screen color is per device. Color preserves RGB; Green/Black & White use luminance phosphors; Amber shifts from brown/orange at low emission to golden yellow at high emission. Amber also samples a 12-frame indexed history (~240 ms): each C64 pixel starts at one of 16 palette-derived luminances, while fractional-frame exponential decay produces smooth analog temporal persistence.

Dirty Glass combines a packaged photographic lint material with static procedural grime, smudges, tiny mineral deposits/refraction, fine dust and isolated dark flecks. It is fixed in glass space while video moves underneath and is included in filtered screenshots.

The CRT Tube face has an invariant dark charcoal glass base independent of C64 signal black or picture controls. Its **bezel reflection** models a plastic wall roughly 85° to the glass with a slight overlapping lip, one continuous mapping of the first ~1.5–5 mm screen strip, sub-pixel rough-plastic diffusion and broad outward falloff. A centered-view perspective keeps each wall midpoint front-facing and bends the mapping progressively toward the screen centerlines near corners. Single lines remain single and never diverge.

Output is **dithered** (±0.5 LSB hash noise) to prevent 8-bit banding rings in the vignette and reflection gradients — visible when brightness is raised or contrast lowered.

Monitor picture controls (brightness/contrast in signal space; saturation/tint as YIQ chroma rotation — exactly what the real pots did) apply as shader uniforms in every mode. Knob drags write to a plain `PictureControls` object the renderer reads per frame, bypassing SwiftUI so adjustments track at full frame rate.

### Keyboard

The Ultimate's REST API has **no keyboard endpoint** (verified against firmware 3.14 and the device's own web UI). Stream64 types by DMA: PETSCII codes are written to the C64's KERNAL keyboard buffer at `$0277` with the pending count at `$C6`, via `machine:writemem`, in chunks of 10 (the buffer size), polling for drain between chunks.

Keystrokes flow through a **single serialized queue** per device — concurrent writers would race on the buffer and drop or reorder keys. Failures retry once, then surface in a banner without touching connection state. The buffer is flushed at machine-state boundaries (reset, reboot, PRG load) so unconsumed keys can't replay into the next program.

Limitation inherent to the approach: programs that read the keyboard through the KERNAL (BASIC, most utilities) receive input; games scanning the hardware matrix directly do not.

### File Loading

Drag-and-drop accepts PRG and disk images: `.prg` uses `POST /v1/runners:run_prg` (reset, DMA-load, run); D64/G64/D71/G71/D81 use multipart `POST /v1/drives/a:mount`. The file never needs to exist on Ultimate storage, and ⌃-drop fans it out to connected sessions. SID and CRT runner support is used by Assembly64 and safe archive loading, not the current drag target.

**Mount & Run** (Assembly64 browser) chains mount → machine reset → a 3 s BASIC-boot wait → keyboard-buffer injection of `LOAD"*",8,1` and `RUN` — fully automatic disk boot.

### Assembly64 Integration

`Assembly64Client` talks to the [Assembly64](https://hackerswithstyle.se/leet/swagger-ui/index.html) REST API (requires `client-id: assembly64`). Search facets are loaded from `/search/aql/presets`; tested AQL composition handles quoting, repository/type/year/rating/recency filters, sorting and pagination. Composite release identity prevents cross-repository collisions. Selecting a result concurrently loads files and cached metadata, with CSDB preview/source fallback. Favorites, recents, saved searches and successful remembered actions persist locally. Complete release ZIPs can be saved or safely inspected: traversal, symlinks, duplicates, suspicious ratios and size/count limits are rejected before selective in-memory extraction and device loading.

## Design Notes & Learned Constraints

Decisions that came out of real debugging, preserved here so they don't get "simplified" away:

- **Sessions live in `SessionManager` held by `@StateObject`.** SwiftUI discards `@State` writes made during body evaluation and recreates plain-property objects when the view struct rebuilds — both variants caused duplicate sessions (black screens, phantom audio) before landing here.
- **Triple-buffered frame textures.** With expensive fragment shaders (CRT modes), uploading into the texture the GPU is reading tears the picture. Sharp mode never showed it; Composite/RF did.
- **fps publishes only on ≥0.5 changes.** Per-second `@Published` updates re-rendered every observer — including rebuilding (and collapsing) any open context menu.
- **Context menus snapshot state rather than observe it.** A menu that observes live objects gets rebuilt mid-traversal.
- **`VideoView` observes `DisplaySettings` directly.** The renderer receives settings in `updateNSView`, which only runs when that view re-renders — hosts (grid tiles) don't necessarily re-render on settings changes.
- **Stream pickup compares lifetime-counter baselines.** Receiver packet totals survive listener restarts; comparing them with zero skipped `stream:start` after reconnect. Each connect now requires post-baseline packet growth.
- **Stop, settle, then start.** C64 Ultimate 1.1.0 can report "Network Host Resolve Error" if start immediately follows stop. The app stops requested streams, waits one second, then starts them; persistent failure retains Reboot & Retry.
- **REST errors can arrive inside HTTP 2xx.** Non-empty device `errors` arrays are treated as failures instead of trusting status code alone.
- **Only one Stream64 process may own UDP ports.** A POSIX lock activates the existing process and exits duplicate launches.
- **Occluded windows stop MTKView's display link.** A timer-driven `draw()` fallback keeps background playback smooth (e.g. grid + overlapping window).
- **One audible device at a time**, enforced centrally by the session manager on selection/mode changes — per-tile mute juggling left orphaned unmuted streams after view teardown.
- **Closing a viewer means full termination.** SwiftUI root-view disappearance and AppKit termination both close every Assembly64/Help/Settings/extra-viewer window before exit.

## The Ultimate REST API (as used)

| Endpoint | Use |
|---|---|
| `GET /v1/info` | Connectivity check, product/firmware display |
| `PUT /v1/streams/video:start?ip=<mac>:<port>` | Start VIC stream to this Mac (same for audio) |
| `PUT /v1/machine:reset / :reboot / :pause / :resume / :poweroff / :menu_button` | Machine control |
| `GET/PUT /v1/machine:readmem / :writemem` | Keyboard-buffer injection ($0277/$C6) |
| `POST /v1/runners:run_prg` | Upload + run a PRG (binary body) |
| `POST /v1/drives/a:mount` | Upload + mount a disk image (multipart) |
| `POST /v1/runners:sidplay` | Upload + play a SID tune |
| `POST /v1/runners:run_crt` | Upload + run a cartridge image |

Requests carry the `X-Password` header when the device has an API password set.

## License

GPL-3.0 — see [LICENSE](LICENSE).

Release history: [CHANGELOG.md](CHANGELOG.md).
