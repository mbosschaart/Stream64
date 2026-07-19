# Stream64

A native macOS viewer and remote control for the **Commodore 64 Ultimate** family (Ultimate 64, Ultimate 64 Elite, Ultimate-II+). Stream64 receives the device's live video and audio streams over the network and renders them with Metal — with authentic CRT simulation, working monitor bezels, full keyboard input, drag-and-drop file loading, and simultaneous multi-device viewing.

Designed by Martijn Bosschaart, 2026.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-green)

## Features

- **Live video/audio streaming** — the Ultimate's VIC video stream (384×272 @ ~50 fps PAL) and SID audio (47983 Hz stereo) over UDP, rendered via Metal with sub-frame latency
- **CRT simulation** — scanlines, phosphor mask, bloom, curved-glass tube with rounded corners, vignette, and a geometrically correct reflection of the picture on the tube's black mask
- **Signal-path simulation** — S-Video (clean), Composite (chroma bleed, dot crawl, ghosting), or RF (snow, line jitter, interference bar, ghosting — plus matching TV-speaker audio: mono, band-limited, static, mains hum)
- **Monitor bezels** — Commodore 1702 and 1084S, drawn in SwiftUI. The 1702's front-panel door opens to reveal **working knobs** (volume, brightness, color, tint, contrast) that drive the picture live
- **Multi-device** — view all machines simultaneously in a grid, each with its own rendering settings; one-click audio switching; ←/→ channel-surfing in fullscreen
- **File loading** — drag a `.prg` or disk image (`.d64/.g64/.d71/.g71/.d81`) onto any stream; hold ⌃ to **Multi Drop** onto every connected machine at once
- **Assembly64 library browser** — search the online C64 library (CSDB, GameBase64, HVSC, OneLoad64, …) and load results straight onto a machine: run PRGs, **Mount & Run** or **Mount** disk images, play SIDs, start cartridges
- **Keyboard input** — type on the C64 from your Mac (KERNAL keyboard-buffer injection over DMA), plus a full on-screen C64 keyboard with PETSCII shift combinations
- **Machine control** — reset, reboot (with automatic stream re-arm), pause/resume, menu button, power off
- **In-app documentation** — Help → Stream64 Help (⌘?)

## Requirements

- macOS 14 (Sonoma) or newer, Apple Silicon
- A C64 Ultimate device with firmware **3.11+** on the same network
- UDP path from device to Mac (no firewall blocking the stream ports)

## Building & Running

Stream64 is a Swift Package — no Xcode project needed:

```sh
swift run
```

Or open the folder in Xcode and run the `Stream64` scheme.

## Quick Start

1. Launch Stream64 and click **Add Device…** (⇧⌘N)
2. Enter the device's IP address or hostname; **Test Connection**; **Add**
3. The viewer connects automatically: it verifies the device over REST, opens local UDP listeners, and asks the device to stream to your Mac

Right-click the picture for every control; the same options live in the toolbar.

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

Each configured device gets one `DeviceSession` owning its own receivers, API client, and display settings. Sessions are cached in a `SessionManager` and survive view rebuilds; devices stream to distinct local UDP port pairs so any number can run simultaneously.

## Source Layout

```
Sources/Stream64/
├── Stream64App.swift          App entry, menu bar, Help/About, window lifecycle
├── Models/
│   ├── UltimateDevice.swift   Device config (address, ports, auto-connect)
│   ├── DeviceStore.swift      Persistence (Application Support/Stream64/devices.json)
│   ├── AppSettings.swift      Global prefs (audio, network, general) — @AppStorage
│   ├── DisplaySettings.swift  Per-device rendering settings, persisted by device UUID
│   └── PETSCII.swift          ASCII/Unicode → PETSCII encoding for keyboard input
├── Services/
│   ├── UltimateAPIClient.swift  REST client for the Ultimate's /v1 API
│   ├── Assembly64Client.swift   Assembly64 library API (AQL search, downloads)
│   ├── DeviceSession.swift      Connection lifecycle, keyboard queue, file loading
│   ├── VideoReceiver.swift      UDP listener; assembles 4bpp packets into frames
│   └── AudioReceiver.swift      UDP listener; ring buffer → AVAudioSourceNode; RF filter
├── Rendering/
│   └── MetalFrameRenderer.swift Metal pipeline + all shaders (palette, CRT, signal sim)
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
```

## The Data Path

### Video

The Ultimate sends the VIC frame as UDP packets: a 12-byte header (sequence, frame number, line number with a last-packet flag, pixels-per-line, lines-per-packet, bits-per-pixel) followed by 4-bit palette indices. `VideoReceiver` assembles lines into a 384×272 byte buffer and hands completed frames to the renderer.

`MetalFrameRenderer` uploads each frame into a **ring of three `r8Uint` textures** (never writing a texture the GPU may still be reading — a CPU `replace()` during a slow fragment shader pass tears the picture) and draws a fullscreen quad. The fragment shader does palette lookup on the GPU from a 16×1 palette texture, so the CPU never touches RGB.

The scaling math targets a **4:3 display aspect** (the C64's pixels are not square; 384×272 ≈ 1.41:1 as raw pixels but a real C64 fills a 4:3 tube). Fit letterboxes, Integer steps in whole multiples of the source height.

### Audio

The audio stream is 16-bit stereo at 47983 Hz (the Ultimate's actual PAL-derived rate), 192 sample pairs per packet. `AudioReceiver` uses a **pull model**: an `AVAudioSourceNode` render callback pulls from a lock-guarded ring buffer. A jitter buffer (default 60 ms, configurable) absorbs network variance; backlog beyond the target is trimmed so latency is bounded and can never ratchet upward — network hiccups produce a brief silence, not permanent delay.

The **RF audio filter** (active when a stream's input signal is RF and a CRT filter is rendering) runs inside the render callback: mono fold, two-pole ~3 kHz low-pass, ~200 Hz high-pass, tanh soft-clip drive, low-passed hiss bed and 50 Hz hum. All per-sample with no allocations on the audio thread.

### Rendering & Shaders

All shaders live as source in `MetalFrameRenderer.swift` and compile at app launch. The pipeline per filter mode:

| Mode | Shader work |
|---|---|
| Sharp | Nearest-neighbor palette lookup |
| Smooth | Manual bilinear blend of palette-expanded texels |
| CRT | `crtShade`: luminance-dependent scanlines, RGB phosphor stripe, horizontal bloom |
| CRT Tube | Everything above + barrel distortion, rounded-corner SDF mask, vignette, and mask reflection |

Signal simulation (`compositeSample`) runs before the CRT treatment, in **YIQ space**: gaussian luma soften, wide asymmetric chroma smear (bandwidth collapse), comb-filter dot crawl on chroma edges, displaced-copy ghosting. RF adds animated snow, per-scanline jitter, a drifting interference line, and stronger everything, driven by a frame-counter time uniform.

The **tube reflection** mirrors each mask pixel's position across the nearest point of the curved face edge (via the SDF gradient), so every strip of the black mask reflects the picture content directly adjacent to it — a bright sprite at the screen edge glows onto the mask beside it. Falloff is exponential with distance from the glass; a gaussian tangential blur stands in for matte plastic.

Output is **dithered** (±0.5 LSB hash noise) to prevent 8-bit banding rings in the vignette and reflection gradients — visible when brightness is raised or contrast lowered.

Monitor picture controls (brightness/contrast in signal space; saturation/tint as YIQ chroma rotation — exactly what the real pots did) apply as shader uniforms in every mode. Knob drags write to a plain `PictureControls` object the renderer reads per frame, bypassing SwiftUI so adjustments track at full frame rate.

### Keyboard

The Ultimate's REST API has **no keyboard endpoint** (verified against firmware 3.14 and the device's own web UI). Stream64 types by DMA: PETSCII codes are written to the C64's KERNAL keyboard buffer at `$0277` with the pending count at `$C6`, via `machine:writemem`, in chunks of 10 (the buffer size), polling for drain between chunks.

Keystrokes flow through a **single serialized queue** per device — concurrent writers would race on the buffer and drop or reorder keys. Failures retry once, then surface in a banner without touching connection state. The buffer is flushed at machine-state boundaries (reset, reboot, PRG load) so unconsumed keys can't replay into the next program.

Limitation inherent to the approach: programs that read the keyboard through the KERNAL (BASIC, most utilities) receive input; games scanning the hardware matrix directly do not.

### File Loading

Dropped files upload directly over REST: `.prg` via `POST /v1/runners:run_prg` (binary body — reset, DMA-load, run) and disk images via `POST /v1/drives/a:mount` (multipart attachment) with type inferred from the extension. The file never needs to exist on the Ultimate's storage. ⌃-drop fans the upload out to every connected session in parallel. SID tunes go to `runners:sidplay`, cartridges to `runners:run_crt`.

**Mount & Run** (Assembly64 browser) chains mount → machine reset → a 3 s BASIC-boot wait → keyboard-buffer injection of `LOAD"*",8,1` and `RUN` — fully automatic disk boot.

### Assembly64 Integration

`Assembly64Client` talks to the [Assembly64](https://hackerswithstyle.se/leet/swagger-ui/index.html) REST API (requires a registered `client-id` header on every request). Search uses **AQL** — space-separated `key:value` terms (`name:turrican subcat:games sort:name order:asc`); multi-word values must be quoted or the parser rejects the query (errorCode 463, returned as an HTTP 200 with an `{"errorCode": N}` body — the client sniffs small responses for this envelope before decoding). The flow is `search/aql/{offset}/{limit}` → `search/entries/{item}/{category}` (an item's files: disk sides, versions) → `search/bin/{item}/{category}/{file}` (raw bytes), which stream from the library into memory and straight to the device.

## Design Notes & Learned Constraints

Decisions that came out of real debugging, preserved here so they don't get "simplified" away:

- **Sessions live in `SessionManager` held by `@StateObject`.** SwiftUI discards `@State` writes made during body evaluation and recreates plain-property objects when the view struct rebuilds — both variants caused duplicate sessions (black screens, phantom audio) before landing here.
- **Triple-buffered frame textures.** With expensive fragment shaders (CRT modes), uploading into the texture the GPU is reading tears the picture. Sharp mode never showed it; Composite/RF did.
- **fps publishes only on ≥0.5 changes.** Per-second `@Published` updates re-rendered every observer — including rebuilding (and collapsing) any open context menu.
- **Context menus snapshot state rather than observe it.** A menu that observes live objects gets rebuilt mid-traversal.
- **`VideoView` observes `DisplaySettings` directly.** The renderer receives settings in `updateNSView`, which only runs when that view re-renders — hosts (grid tiles) don't necessarily re-render on settings changes.
- **The device-side streaming stack can transiently refuse** `streams/*:start` with "Network Host Resolve Error" (firmware 3.14) while its web server stays healthy. The app retries once after 1 s; persistent refusal gets a Reboot & Retry recovery path. A genuinely wedged stack survives until device reboot.
- **Occluded windows stop MTKView's display link.** A timer-driven `draw()` fallback keeps background playback smooth (e.g. grid + overlapping window).
- **One audible device at a time**, enforced centrally by the session manager on selection/mode changes — per-tile mute juggling left orphaned unmuted streams after view teardown.

## The Ultimate REST API (as used)

| Endpoint | Use |
|---|---|
| `GET /v1/version`, `/v1/info` | Connectivity check, product/firmware display |
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
