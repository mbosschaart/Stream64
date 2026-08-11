# Stream64

A native macOS viewer and remote control for the **Commodore 64 Ultimate** family (C64 Ultimate, Ultimate 64, Ultimate 64 Elite, Ultimate-II+). Stream64 receives the device's live video and audio streams over the network and renders them with Metal — with authentic CRT / signal simulation, full keyboard input, drag-and-drop file loading, and simultaneous multi-device viewing.

Designed by Martijn Bosschaart, 2026.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-green)
![Version](https://img.shields.io/badge/version-0.112b-purple)
![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-red)

![Stream64 focus view with CRT Tube rendering](Screenshots/Focus%20view.png)

## Features

- **Live video/audio streaming** — the Ultimate's VIC video stream (384×272 @ ~50 fps PAL) and SID audio (47983 Hz stereo) over UDP, rendered via Metal with low video latency, automatic reconnect/stream re-arm, stop-settle-start firmware recovery, and packet-baseline liveness checks
- **Automatic device discovery** — bounded, cancellable Ethernet/Wi-Fi subnet scanning finds Ultimate REST endpoints, shows product/firmware details, and prefills setup with collision-free local stream ports; manual addressing remains available
- **CRT simulation** — luminance-aware scanlines, monitor-specific shadow-mask pitch (1084S 0.42 mm, 1702 0.64 mm), bloom, curved glass, vignette, reflection, selectable Color/Amber/Green/Black & White phosphors, long analog Amber afterglow sourced from the C64's indexed 16-color history, and per-device CRT optics knobs (scanlines / bloom / phosphor mask / barrel)
- **Signal-path simulation** — S-Video (clean), Composite (strong asymmetric chroma bleed, dot crawl, ghosting), or RF (snow, line jitter, interference bar, stronger ghosting — plus matching TV-speaker audio: mono, two-pole bass/treble roll-off, distortion, static, mains hum)
- **Dirty Glass mode** — optional years-of-neglect layer for CRT modes with photographic corner lint, procedural film/dust/dark flecks, separated smudges, droplet-sized mineral residue, subtle refraction, warm haze and contrast loss
- **Multi-device** — view all machines simultaneously in a grid, each with its own rendering settings; one-click audio switching; ←/→ channel-surfing and five-second pointer auto-hide in fullscreen
- **App-wide AirPlay audio** — one global toolbar route picker sends whichever C64 is currently selected to an AirPlay receiver without changing the Mac's system output; once selected, the route remains locked until explicitly stopped, including during view/C64 switching, resets, and transient transport gaps (AirPlay adds roughly 1–3 seconds of buffering)
- **In-app updates** — optionally checks the latest stable GitHub release at startup, downloads the architecture-matched ZIP, verifies SHA-256 and Developer ID Team ID, then replaces the app and relaunches (with a GitHub release-page fallback)
- **File loading** — drag a `.prg`, `.sid`, `.crt`, or disk image (`.d64/.g64/.d71/.g71/.d81`) onto any stream; hold ⌃ to **Multi Drop** onto every connected machine at once
- **Audio output device picker** — choose which Mac speaker/headphones Stream64 uses locally (independent of the system default and of AirPlay)
- **Commander file manager** — dual panes independently browse Home/internal/USB Mac volumes or any configured Ultimate, with C64-to-C64 transfers, Space-to-mark batch selection, Finder drag-and-drop, queued file operations, direct remote run/mount/play, and simultaneous **All Connected C64s** targets
- **Assembly64 search browser** — search the online C64 library with rich filters, favorites, previews, safe ZIP inspection, remembered actions, and Run/Play/Mount/Mount & Run targeting one machine or **All Connected C64s** simultaneously
- **Keyboard and joystick input** — capability-probed matrix press/release with symbolic/positional keymaps, safe KERNAL-buffer fallback, Arrow/configurable-fire-key virtual joystick, native macOS game-controller support, port switching, and release-all focus safety
- **Machine control** — reset, reboot, pause/resume, and power off; the toolbar's Menu button opens the Ultimate Menu (U64/Elite only — see below) rather than pressing the physical menu button, since it doesn't interrupt whatever's running on the C64 the way the physical button does
- **Debug Trace & Ultimate Menu** (Ultimate 64/Elite only) — a live decoded view of the 6510/VIC/1541 bus-trace stream with raw/CSV export; its Memory Map offers fading I/O activity, persistent byte-value depth, and a rotatable Metal 3D terrain of all 65,536 addresses with adaptive detail, hover inspection, region overlays and activity pulses. The separate Telnet/VT100 Ultimate Menu exposes the on-device menu system (and, if navigated there, the Machine Code Monitor) without interrupting the C64; both windows are hidden automatically on hardware that doesn't implement the U64 debug register
- **SID Oscilloscope** (Ultimate 64/Elite only) — a 19-mode SID visualizer picked from a "SID Visualizations" right-click menu, with any number of modes open at once, each in its own window (or all 19 at once, auto-tiled into a grid, via "Open All in Grid"), and the whole arrangement savable/restorable per device: per-voice Oscilloscope/ADSR Envelope/Mixer Console/ADSR Knobs/Pulse Width/Control Bits/Piano Keyboard (reconstructed from register writes on the debug bus-trace), Piano Roll, Voice Lineup, VU Meter Bank, Register Activity Grid, an approximate Filter Curve, a per-chip SID Dashboard, a Colorful Waveform showcase, plus real-audio-driven Spectrum Analyzer, Lissajous Scope, piano-key-labeled Spectrogram, and sndpeek-style 3D Waterfall/3D Bar Field modes — with an optional phosphor-glow overlay
- **Filtered screenshots** — toolbar camera, context menu, File command or ⇧⌘S saves exactly what Metal renders, including CRT curvature, signal artifacts, phosphor color/afterglow, reflection and dirty glass
- **Single-instance safety** — repeated launches activate the existing app instead of creating competing UDP listeners; closing any viewer fully closes Assembly64/Help/Settings and terminates the process
- **Branded macOS experience** — native Stream64 app icon, centered standalone launch splash with version display, and a custom About window linking Retro8BITShop
- **In-app documentation** — Help → Stream64 Help (⌘?)

## Screenshots

### All Screens

Monitor multiple Commodore 64 Ultimates at once, each with independent CRT, signal, phosphor, and scaling settings.

![Stream64 All Screens multi-device view](Screenshots/All%20Screens%20view.png)

### Assembly64

Search, preview, favorite, inspect, and run software from the Assembly64 library directly on a selected Ultimate.

![Stream64 Assembly64 interface](Screenshots/Assembly64%20interface.png)

### Commander File Manager

Browse any configured Ultimate or mounted Mac volume in either pane, then queue Mac-to-C64, C64-to-Mac, or C64-to-C64 transfers.

![Stream64 Commander file manager](Screenshots/File%20commander.png)

## Requirements

- macOS 14 (Sonoma) or newer, Apple Silicon or Intel with a Metal-capable GPU
- Ultimate 64/Elite firmware **3.11+**, or C64 Ultimate firmware **1.1+**, on the same network
- UDP path from device to Mac (no firewall blocking the stream ports)

## Upcoming Ultimate Firmware 3.15

Matrix-level keyboard capture, virtual joystick injection, and the remote \
character-based menu require the new REST input APIs in **Ultimate firmware \
3.15 or newer**. Firmware 3.15 currently exists as an official \
[source-tagged release candidate](https://github.com/GideonZ/1541ultimate/tree/v3.15), \
but the public [Ultimate firmware download page](https://ultimate64.com/Firmware) \
still lists 3.14d as the latest normal end-user download.

Stream64 capability-probes these endpoints and never assumes support from the \
version string alone:

### Matrix keyboard input

```http
POST /v1/machine:input
Content-Type: application/json
```

```json
{"events":[{"kind":"keyboard","inputs":["a"],"transition":"press"}]}
```

Keyboard events support `tap`, `press`, and `release`, including chords such \
as `["left_shift","1"]`. This enables held keys and software that scans the \
C64 keyboard matrix directly. Unsupported firmware automatically falls back \
to ordered KERNAL-buffer typing over DMA.

### Virtual joystick input

```json
{"events":[{"kind":"joystick","port":2,"inputs":["left"],"transition":"press"}]}
```

Joystick inputs are `up`, `down`, `left`, `right`, and `fire`, sent with \
matching press/release transitions. Stream64 maps Arrow keys plus a configurable \
fire key, and also supports Apple GameController D-pads, sticks, and buttons.

### Input cleanup

```json
{"events":[{"kind":"release_all"}]}
```

Stream64 sends `release_all` on focus loss, controller disconnect, device \
switching, reset/reboot, and teardown so no key or joystick direction remains \
stuck.

### Remote menu screen

```http
GET /v1/machine:menu_screen
```

The response is exactly 2,000 bytes: a 40×25 character matrix followed by a \
40×25 foreground/background colour matrix. Stream64 renders it in a live, \
keyboard-controlled child window. Older firmware returns 404 and keeps using \
the normal video-stream menu.

See the upstream [CIA-level input implementation PR](https://github.com/chrisgleissner/c64stream/pull/120) \
and [menu-screen firmware PR](https://github.com/GideonZ/1541ultimate/pull/703) \
for the originating protocol details. U2-family cartridges reportedly do not \
support matrix/joystick input, and the C64 Ultimate 1.x firmware line requires \
independent capability probing.

## Debug Trace, Ultimate Menu & SID Oscilloscope (U64/U64 Elite)

Three more capability-probed windows expose facilities documented in the \
[Ultimate data-streams](https://1541u-documentation.readthedocs.io/en/latest/data_streams.html) \
and [API](https://1541u-documentation.readthedocs.io/en/latest/api/api_calls.html) \
docs. All three are U64/U64 Elite only — Stream64 probes `GET /v1/machine:debugreg` \
once connected and hides the menu entries entirely on hardware that returns an \
error (Ultimate-II+, C64 Ultimate).

### Debug Trace

```http
PUT /v1/configs/Data Streams/Debug Stream Mode?value=<mode>
PUT /v1/streams/debug:start?ip=<mac>:<port>
```

Streams cycle-accurate 6510, VIC, or 1541 drive bus accesses as UDP packets \
(default port 11002) and decodes them live into a table of address/data/R-W/ \
PHI2/signal-flag columns, alongside whatever video/audio is already \
streaming — Ultimate's docs claim the debug and video streams are mutually \
exclusive, but that didn't hold up against a real device (see below), so \
Stream64 no longer stops the picture to take a trace. Raw capture exports \
in the same layout the official `grab_debug.py`/`dump_bus_trace.c`/GtkWave \
pipeline already expects; visible rows can also be exported as CSV.

Mode selection uses the `Data Streams` → `Debug Stream Mode` config item — \
confirmed live against a real Ultimate 64-II on firmware 3.15, which also \
exposed two IEC-bus variants (`6510 w/IEC`, `6510 & VIC w/IEC`) beyond the \
five modes the public docs describe. An earlier version of this feature \
guessed the U64 debug register ($D7FF) controlled mode selection instead; \
live testing disproved that directly (every value produced identical \
output) before the real mechanism was found. The register is still real and \
still U64-only — Stream64 just uses it for capability detection now, not \
mode selection.

Mutual exclusivity with video/audio was tested the same way and also \
disproved: starting a debug trace while video/audio were already running \
didn't interrupt them, and (re)starting video while a trace was running \
didn't interrupt that either — all three streamed simultaneously for the \
full test window.

A **Memory Map** view (toggle in the toolbar, the default) shows the same \
trace as a 256×256 address matrix — row = address page, column = address \
low byte. Its toolbar offers three sub-visualizations: **I/O Fade** shows \
recent reads (green) and writes (orange) with adjustable 20 ms–1 s decay; \
**Byte Load** keeps the last observed byte at each address, with `$00` \
black through `$FF` fully bright; and **3D Map** turns all 65,536 positions \
into a rotatable/zoomable Metal terrain whose bar heights are byte values. \
The 3D view supports hover address/value/region inspection, recent-access \
pulses, subtle RAM/ROM/I/O region overlays, and adaptive 1×1/2×2/4×4/8×8 \
detail to protect the main C64 renderer — each enhancement is independently \
toggleable. Double-click or the toolbar button resets the isometric camera. \
Flat-map landmarks cover zero page, stack, screen RAM, BASIC/KERNAL ROM, \
VIC-II, SID, color RAM, both CIAs, cartridge I/O and banked Character ROM; \
they switch automatically to the 1541 RAM/VIA/DOS-ROM map for drive traces.

[![3D Memory Map demonstration](Screenshots/3D%20Memory%20Map%20demonstration.jpg)](https://www.youtube.com/watch?v=1IorunGODNw)

### Ultimate Menu

Opened from the toolbar's Menu button or the stream's right-click menu. \
The on-device menu system and Machine Code Monitor are native firmware \
UI with no REST equivalent. Stream64 opens a VT100 terminal window over the \
Ultimate's Telnet server (port 23) instead — the transport its own manual \
documents for remote menu/monitor control, and, unlike the REST-based menu \
button/`menu_screen` path, one that doesn't interrupt whatever's running on \
the C64. In everyday use this window is mostly a live view of the on-screen \
menu (hence its name), though the same VT100 session can also reach the \
real Machine Code Monitor if navigated there. The menu's own text (labels, \
status lines) is plain mixed-case ASCII and is decoded as such; its box \
borders and side rails use the standard VT100 DEC Special Graphics \
line-drawing character set (`ESC ( 0`/SO/SI) rather than PETSCII, and are \
decoded as such too, instead of showing as literal "q"/"x"/"j"/"k" letters. \
The decoder also correctly consumes DEC private-mode sequences like \
`ESC[?25l` (cursor hide) instead of ending the escape sequence early and \
dumping the rest onto the screen as text — on some firmware that toggles \
these on every cursor blink, that bug could scroll all real menu content \
off-screen, leaving the window looking blank/frozen. Telnet's own \
protocol-negotiation bytes (sent by the device immediately on connect, \
before any VT100 content) are filtered out before decoding too, instead \
of showing up as a few stray characters at the very start of the screen. \
Arrow and function keys navigate using standard xterm \
escape sequences; `Command+letter` sends the conventional "Meta sends \
escape" prefix as a best-effort stand-in for the physical `C=` modifier \
(`C=+O` opens the monitor, `C=+I` swaps overlay/freeze mode, and so on) — \
unverified over Telnet, since modifier-heavy shortcuts are known to \
sometimes need different handling on that transport.

### SID Oscilloscope

A 19-mode SID visualizer — 3 channels normally, 6 when a second SID is \
configured (base address and channel count auto-detected from `SID \
Addressing`/`SID Sockets Configuration`, confirmed live against a real \
dual-8580 U64-II). Reached from the stream's right-click menu under "SID \
Visualizations", which lists every mode directly — picking one always opens \
a brand-new, fully independent window already set to that mode, so, for \
example, an Oscilloscope window and a Spectrum Analyzer window can both be \
open and updating live side by side; there's deliberately no toolbar/pulldown \
menu inside a visualization window itself for switching its mode — a window's \
mode is fixed once opened, and its own right-click context menu offers the \
same "pick a mode, get a new window" list (plus a Phosphor Glow toggle for a \
CRT-bloom overlay) for convenience without having to go back to the stream's \
menu. "Open All in Grid" (in both menus) opens every mode at once, each in \
its own window at its minimum usable size, automatically tiled into a grid \
centered on screen. However the windows end up arranged — from "Open All in \
Grid" or hand-picked and nudged into place — "Save Window Layout" (also in \
both menus) remembers every open window's mode, position, and size per \
device, so "Restore Window Layout" can bring back that exact arrangement \
later, even after quitting and relaunching the app (Save overwrites whatever \
was stored for that device); both are on the stream's menu too so restoring \
works even with no SID windows currently open.

Fourteen modes are register-driven — reconstructed from SID register *writes* \
seen on a 6510-capable Debug Trace, since there's no way to read individual \
voices off the wire (the audio stream is only the final post-mix output), \
through a small approximate SID emulation core (oscillator shapes, a \
standard-timing-table ADSR envelope, a noise LFSR, and a simplified \
ring-modulation approximation — not cycle-exact; see `HANDOVER.md` §15-16 \
for specifics worth knowing before treating any of it as reference-accurate):

- **Oscilloscope** — the original per-channel scrolling waveform, with waveform combination, frequency, note name, and gate state
- **ADSR Envelope** — the same per-channel grid, plotting the envelope curve instead of the waveform
- **Mixer Console** — a denser per-channel strip: waveform + VU meter + ADSR-stage badge + note/frequency
- **Piano Roll** — all channels on one shared pitch axis, showing note-on runs over the last ~10 seconds
- **Piano Keyboard** — a per-channel piano keyboard whose keys press and light up to match the tone each voice is currently playing
- **Voice Lineup** — every channel as a stacked, time-aligned lane with note-name labels at each onset and dashed guide lines wherever two or more channels change notes at (nearly) the same moment — a chiptune's version of a chord hit, inspired by Sonic Lineup's multi-track alignment view
- **Filter Curve** — an approximate frequency-response curve per chip from the (newly decoded) filter/resonance/mode registers, plus which channels are routed through it
- **VU Meter Bank** — large, bold per-channel level meters with a peak-hold notch, laid out like a real mixing console's meter bridge
- **Register Activity Grid** — a compact heatmap of the SID's own ~25 writable registers per chip, labeled by mnemonic (`V1 FREQ LO`, `V2 CTRL`, `FC HI`, etc.) and lighting up on each write — shows what the player routine is actually doing at the register level, not the resulting audio
- **ADSR Knobs** — the raw Attack/Decay/Sustain/Release register values (0-15) per channel as bars, each labeled with its real millisecond time — distinct from the ADSR Envelope mode, which shows the resulting curve, not the knob settings
- **Pulse Width** — a duty-cycle gauge for the 12-bit pulse-width register per channel, with a small preview of the resulting pulse shape — surfaces PWM-sweep effects invisible in every other mode
- **Control Bits** — an LED-style indicator grid per channel for all 8 control-register bits (Gate/Sync/Ring/Test/Triangle/Sawtooth/Pulse/Noise) at a glance
- **SID Dashboard** — one compact per-chip summary: active voice count, master volume, filter mode/cutoff/resonance, and which channels are routed through the filter
- **Colorful Waveform** — all channels' waveforms overlaid on one canvas in vibrant colors with a phosphor-glow bloom, a style/showcase mode over the same data the plain Oscilloscope mode uses

Five modes read the real post-mix Ultimate audio stream instead (so they reflect genuine SID output, including real filter behavior the register-driven modes only approximate), scaled with a self-adjusting auto-gain (peak-hold-with-slow-release, like an analog VU meter) rather than a fixed level so they react to how loud the content actually is — with an absolute silence check underneath the auto-gain so the FFT-based ones (Spectrum Analyzer, Spectrogram, 3D Waterfall, 3D Bar Field) go quiet once playback actually stops, instead of auto-gain rescaling the residual noise floor up to full brightness:

- **Spectrum Analyzer** — a classic FFT bar-graph EQ display
- **Lissajous Scope** — left channel plotted against right channel (stereo-phase visualization)
- **Spectrogram** — a scrolling time-vs-frequency heatmap with a piano-key-labeled axis and a black/purple/red/orange/yellow "fire" color ramp
- **3D Waterfall** — the same spectrum history as a scrolling 3D-look wireframe waterfall, sndpeek-style
- **3D Bar Field** — the same history again, as filled 3D-look bars in a blue/purple/pink/orange palette instead of a wireframe line

All of the audio-tap-driven modes process incoming audio in batches at a \
steady 30 Hz rather than reacting to every individual network packet \
(~250 times a second), which cut a real source of lag/overhead — \
especially noticeable with several such windows open via "Open All in \
Grid" — without any loss of visual smoothness, since nothing here needs \
faster than a normal display-refresh-ish update rate anyway.

The register-driven modes need a 6510-inclusive trace running, which the \
window starts automatically and silently as soon as it opens if one isn't \
already — no prompt, no button. It can run alongside the Debug Trace \
window watching the very same trace, and opening several SID Oscilloscope \
windows at once only starts it the first time, not per window.

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
VERSION=0.112b BUILD_NUMBER=112 ARCH=arm64 ./Scripts/build-release.sh

# Intel
VERSION=0.112b BUILD_NUMBER=112 ARCH=x86_64 ./Scripts/build-release.sh
```

Artifacts are written to `dist/<architecture>/`:

- `Stream64.app`
- `Stream64-<version>-macos-<architecture>.zip`
- `Stream64-<version>-macos-<architecture>.dmg`
- `Stream64-<version>-macos-<architecture>-SHA256.txt`

These are separate thin arm64 and x86_64 builds, not one universal binary.

By default the release script **Developer ID–signs and notarizes** the app \
and DMG using an Apple ID + app-specific password. Put credentials in a \
gitignored `.notarize.env` in the repo root (`APPLE_ID`, \
`APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, optional \
`CODESIGN_IDENTITY`), then run the build commands above. Use \
`SIGNING=adhoc` for a local smoke build that skips notarization. Never \
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

Each configured device gets one `DeviceSession` owning its receivers, API client and display settings. Sessions are cached in `SessionManager` and survive view rebuilds. Device defaults and manual edits validate stream-port ranges and collisions. `SingleInstanceLock` prevents separate Stream64 processes from competing for the same listeners. `Assembly64LibraryStore` and `Assembly64Cache` separate persistent user intent from regenerable metadata. Health monitoring, reconnect/backoff, screenshot GPU readback and resource lookup operate around the core stream path.

## Source Layout

```
Sources/Stream64/
├── Stream64App.swift          App entry, menus, Help/About, and window lifecycle
├── Models/
│   ├── AppSettings.swift, DisplaySettings.swift, DeviceStore.swift
│   │                            Global, display, and device persistence models
│   ├── UltimateDevice.swift, RemoteFile.swift
│   │                            Device configuration and remote-file models
│   ├── Assembly64LibraryStore.swift, Assembly64SearchQuery.swift
│   │                            Library state and tested AQL query composition
│   ├── C64Input.swift, C64Keymap.swift, PETSCII.swift
│   │                            Keyboard, joystick, keymap, and PETSCII models
│   ├── DebugStreamEntry.swift, MemoryHeatmap.swift
│   │                            Bus-trace decoding and 64K activity state
│   ├── SIDEngine.swift, SIDVoiceState.swift, SIDFilterState.swift
│   │                            Shared SID synthesis, register, and filter state
│   ├── SIDRegisterActivity.swift, SIDSpectrumAnalyzer.swift
│   │                            SID register heatmaps and audio FFT analysis
│   ├── SIDWindowLayout.swift    Persisted SID visualization window layouts
│   ├── UltimateMenuScreen.swift Remote menu-screen decoding model
│   └── VT100Screen.swift        ANSI/VT100 terminal buffer and parser
├── Services/
│   ├── UltimateAPIClient.swift, UltimateFTPClient.swift
│   │                            REST and FTP clients for Ultimate devices
│   ├── DeviceSession.swift      Connection lifecycle, stream orchestration,
│   │                            health monitoring, recovery, and input
│   ├── VideoReceiver.swift, AudioReceiver.swift
│   │                            UDP video/audio receivers and packet accounting
│   ├── DebugStreamReceiver.swift UDP bus-trace receiver and observers
│   ├── AirPlayOutputController.swift, LiveAirPlayEncoder.swift
│   │                            Persistent app-wide AirPlay and AAC/HLS pipeline
│   ├── UpdateService.swift      GitHub stable-release check, download, verify, install
│   ├── LiveHLSServer.swift      Authenticated temporary LAN HLS origin
│   ├── UltimateTelnetClient.swift  Telnet transport for the Ultimate Menu
│   ├── C64InputController.swift, GameControllerManager.swift
│   │                            Keyboard, matrix, joystick, and controller input
│   ├── DeviceDiscoveryService.swift, LocalNetwork.swift
│   │                            Bounded discovery and network authorization
│   ├── FileOperationCoordinator.swift, LocalFileSystemProvider.swift
│   │                            Local/remote copy, move, conflict, and cleanup flow
│   ├── TransferQueue.swift      Persistent, retryable file-transfer queue
│   ├── Assembly64Client.swift, Assembly64Cache.swift
│   │                            Assembly64 search, metadata, cache, and downloads
│   ├── Assembly64ArchiveInspector.swift  Safe ZIP inspection/extraction
│   ├── CSDBPreviewClient.swift  CSDB screenshot/source fallback
│   └── SingleInstanceLock.swift Process lock preventing duplicate UDP listeners
├── Rendering/
│   ├── MetalFrameRenderer.swift Metal + shaders (CRT/signal/phosphor/history/dirt)
│   └── MemoryMap3DRenderer.swift Instanced 65,536-address 3D memory terrain
├── Resources/
│   ├── dirty-glass-mask.png     Photographic RGBA glass-contamination material
│   ├── logofactuur.png          Branded application logo
│   └── Stream64logo.png         Branded splash/About logo
└── Views/
    ├── ContentView.swift, VideoView.swift
    │                            Main viewer, grid, MTKView, and keyboard capture
    ├── StreamContextMenu.swift, SettingsView.swift, DeviceEditSheet.swift
    │                            Per-stream controls, preferences, and device setup
    ├── Assembly64View.swift, RemoteBrowserView.swift
    │                            Assembly64 browser and Commander file manager
    ├── DebugTraceView.swift, MemoryMapView.swift, MemoryMap3DView.swift
    │                            Trace table, flat map, and 3D map UI
    ├── TelnetMonitorView.swift, RemoteMenuView.swift
    │                            Ultimate Menu terminal and menu-screen windows
    ├── SIDOscilloscopeView.swift
    │                            SID visualization window coordinator
    ├── SID*.swift                SID waveform, mixer, filter, piano-roll,
    │                            spectrum, dashboard, register, and 3D views
    ├── AirPlayRoutePickerView.swift  Native app-only AirPlay route picker
    ├── UpdateSheet.swift          Update status, release notes, and install flow
    ├── PictureControlsView.swift, OnScreenKeyboardView.swift
    │                            Floating picture controls and C64 keyboard
    ├── MonitorBezelView.swift   Retained for future 1702/1084S reintroduction
    ├── SplashView.swift, AboutView.swift  Branded launch/About windows
    └── HelpView.swift           In-app documentation window
Tests/Stream64Tests/             AQL/CSDB, persistence, transfer, archive, stream,
                                 SID, CRT, lock, and Metal regression tests
Scripts/build-release.sh         arm64/x86_64 Developer ID + notarized ZIP/DMG
Packaging/Info.plist             macOS application-bundle metadata
Package.swift / Package.resolved SwiftPM targets, ZIPFoundation and pinned resolution
LICENSE / CHANGELOG.md           License and release history
```

## The Data Path

### Video

The Ultimate sends the VIC frame as UDP packets: a 12-byte header (sequence, frame number, line number with a last-packet flag, pixels-per-line, lines-per-packet, bits-per-pixel) followed by 4-bit palette indices. `VideoReceiver` assembles lines into a 384×272 byte buffer and hands completed frames to the renderer.

`MetalFrameRenderer` uploads each frame into a **ring of three `r8Uint` textures** (never writing a texture the GPU may still be reading — a CPU `replace()` during a slow fragment shader pass tears the picture) and draws a fullscreen quad. The fragment shader does palette lookup on the GPU from a 16×1 palette texture, so the CPU never touches RGB.

The scaling math targets a **4:3 display aspect** (the C64's pixels are not square; 384×272 ≈ 1.41:1 as raw pixels but a real C64 fills a 4:3 tube). Fit letterboxes; Integer steps in whole multiples of the source height, and falls back to Fit when the largest whole-pixel scale would leave most of the window empty (common in awkward fullscreen sizes).

### Audio

The audio stream is 16-bit stereo at 47983 Hz (the Ultimate's actual PAL-derived rate), 192 sample pairs per packet. `AudioReceiver` uses a **pull model**: an `AVAudioSourceNode` render callback pulls from a lock-guarded ring buffer. A jitter buffer (default 60 ms, configurable) absorbs network variance; backlog beyond the target is trimmed so latency is bounded and can never ratchet upward — network hiccups produce a brief silence, not permanent delay.

By default the engine's output is pinned to the current system default output device (rather than left to `AVAudioEngine`'s own default selection) and re-pinned whenever CoreAudio's device graph changes — see `HANDOVER.md` §17 for why this matters when the default output is a multi-output/aggregate device. Settings → Audio can instead lock local playback to a specific output device; that choice is independent of AirPlay.

App-only AirPlay uses a separate global path because macOS's public `AVRoutePickerView` routes an `AVPlayer`, not an arbitrary `AVAudioEngine`. Stream64 converts the currently audible session's live 47983 Hz PCM to 48 kHz AAC, publishes a short bounded audio-only HLS window through an authenticated temporary LAN server, and assigns that one app-wide player to the system picker. Once external playback activates, the app remains locked to that route until the user explicitly chooses **This Mac**/Stop AirPlay: typing, changing views, switching C64s, resets/reboots and temporary source/transport gaps can produce silence or “Connecting…” but never re-enable local output. A real-time silence heartbeat keeps the HLS timeline alive between sources, and switching C64s swaps PCM on that same timeline without changing the AirPlay destination.

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

### Keyboard and Joystick

`C64InputController` serializes every physical/on-screen keyboard and joystick event. It capability-probes `POST /v1/machine:input`: supported firmware receives batched matrix tap/press/release events and `release_all`, enabling held keys and games that scan CIA input directly. Auto mode demotes unsupported firmware to safe 10-byte KERNAL-buffer writes at `$0277/$C6`, with RUN/STOP flag clearing, backpressure, and chunk verification.

Symbolic keymaps follow produced characters; positional keymaps follow Mac physical key positions and can hold C64 Shift/Ctrl/Commodore modifiers. Custom `.c64keymap.ini` files can be imported. F10 toggles virtual joystick mode, F11 switches ports, Arrow keys map to directions, and Backquote (`` ` ``) is the default configurable fire key. Apple `GameController` D-pads, left sticks, and primary buttons feed the same edge-triggered state reducer with deadzone and opposite-direction handling.

All held keyboard/controller state is released on focus loss, app deactivation, controller disconnect, device switch, reset/reboot, and teardown. Current 3.14-era hardware falls back to KERNAL typing; public guidance identifies Ultimate 64 firmware 3.15+ for matrix/joystick support.

### File Loading

Drag-and-drop accepts `.prg` (`POST /v1/runners:run_prg`), disk images (multipart `POST /v1/drives/a:mount`), `.sid` (`POST /v1/runners:sidplay`), and `.crt` (`POST /v1/runners:run_crt`). The file never needs to exist on Ultimate storage, and ⌃-drop fans it out to connected sessions. Assembly64 and Commander use the same runners for remote/library loads.

**Mount & Run** (Assembly64 browser) chains mount → machine reset → a 3 s BASIC-boot wait → keyboard-buffer injection of `LOAD"*",8,1` and `RUN` — fully automatic disk boot.

### Assembly64 Integration

`Assembly64Client` talks to the [Assembly64](https://hackerswithstyle.se/leet/swagger-ui/index.html) REST API (requires `client-id: assembly64`). Search facets are loaded from `/search/aql/presets`; tested AQL composition handles quoting, repository/type/year/rating/recency filters, sorting and pagination. Composite release identity prevents cross-repository collisions. Selecting a result concurrently loads files and cached metadata, with CSDB preview/source fallback. Favorites, recents, saved searches and successful remembered actions persist locally. Complete release ZIPs can be saved or safely inspected: traversal, symlinks, duplicates, suspicious ratios and size/count limits are rejected before selective in-memory extraction and device loading.

## Design Notes & Learned Constraints

Decisions that came out of real debugging, preserved here so they don't get "simplified" away:

- **Sessions live in `SessionManager` held by `@StateObject`.** SwiftUI discards `@State` writes made during body evaluation and recreates plain-property objects when the view struct rebuilds — both variants caused duplicate sessions (black screens, phantom audio) before landing here.
- **Triple-buffered frame textures.** With expensive fragment shaders (CRT modes), uploading into the texture the GPU is reading tears the picture. Sharp mode never showed it; Composite/RF did.
- **fps / presentFPS publish only on ≥0.5 changes.** Per-second `@Published` updates re-rendered every observer — including rebuilding (and collapsing) any open context menu.
- **Context-menu hosts must not observe high-frequency session/SID state.** `ViewerPane` / `ViewerTile` / `SIDOscilloscopeView` keep `.contextMenu` on a non-observing shell; live chrome lives in child views. Menu content (`StreamContextMenu`, `SIDVisualizationMenuContent`) snapshots state instead of observing it.
- **`VideoView` observes `DisplaySettings` only — not `DeviceSession`.** The renderer receives settings in `updateNSView`; session fps ticks must not force `updateNSView` or rebuild parents that own context menus.
- **Prefer the live CRT present path under secondary viz load.** SID ticks and 3D Memory Map rebuilds are cheaper / off-main / yielding when presents slow down; the frame-rate overlay shows `stream / display` when the two diverge.
- **Stream pickup compares lifetime-counter baselines.** Receiver packet totals survive listener restarts; comparing them with zero skipped `stream:start` after reconnect. Each connect now requires post-baseline packet growth.
- **Stop, settle, then start.** C64 Ultimate 1.1.0 can report "Network Host Resolve Error" if start immediately follows stop. The app stops requested streams, waits one second, then starts them; persistent failure retains Reboot & Retry.
- **REST errors can arrive inside HTTP 2xx.** Non-empty device `errors` arrays are treated as failures instead of trusting status code alone.
- **Only one Stream64 process may own UDP ports.** A POSIX lock activates the existing process and exits duplicate launches.
- **Occluded windows stop MTKView's display link.** A timer-driven `draw()` fallback keeps background playback smooth (e.g. grid + overlapping window).
- **One audible device at a time**, enforced centrally by the session manager on selection/mode changes — per-tile mute juggling left orphaned unmuted streams after view teardown.
- **Closing a viewer means full termination.** SwiftUI root-view disappearance and AppKit termination both close every Assembly64/Help/Settings/extra-viewer window before exit.
- **`AVAudioEngine`'s automatic output-device selection isn't trustworthy when the system default output is a multi-output/aggregate device** — it can silently bind to one real hardware device inside it instead of the multi-output device itself, so anything else relying on that same default output (e.g. a separate recording device) gets nothing, even though normal playback sounds completely correct. `AudioReceiver` now explicitly pins to the current default device via `kAudioOutputUnitProperty_CurrentDevice` and re-pins on `AVAudioEngineConfigurationChange` instead of trusting the engine's default. See `HANDOVER.md` §17.

## The Ultimate REST API (as used)

| Endpoint | Use |
|---|---|
| `GET /v1/info` | Connectivity check, product/firmware display |
| `PUT /v1/streams/video:start?ip=<mac>:<port>` | Start VIC stream to this Mac (same for audio) |
| `PUT /v1/machine:reset / :reboot / :pause / :resume / :poweroff / :menu_button` | Machine control |
| `GET/PUT /v1/machine:readmem / :writemem` | Keyboard-buffer injection ($0277/$C6) |
| `POST /v1/machine:input` | Upcoming 3.15+: matrix keyboard/joystick press, release, tap, and release-all |
| `GET /v1/machine:menu_screen` | Upcoming 3.15+: 40×25 menu character and colour matrices |
| `GET/PUT /v1/machine:debugreg` | U64/Elite only: read/write the debug register ($D7FF) that selects the bus-trace source |
| `PUT /v1/streams/debug:start` / `:stop` | U64/Elite only: 6510/VIC/1541 cycle-accurate bus-trace stream (mutually exclusive with video) |
| `GET/PUT /v1/configs/...` | Verify and automatically enable/save required network services |
| `POST /v1/runners:run_prg` | Upload + run a PRG (binary body) |
| `POST /v1/drives/a:mount` | Upload + mount a disk image (multipart) |
| `POST /v1/runners:sidplay` | Upload + play a SID tune |
| `POST /v1/runners:run_crt` | Upload + run a cartridge image |

Requests carry the `X-Password` header when the device has an API password set.

## Input Design Credits

The matrix-input protocol, ordered fallback strategy, focus-release safety, and keymap concepts were informed by [chrisgleissner/c64stream](https://github.com/chrisgleissner/c64stream) (GPL-2.0-or-later). Stream64 reimplements these concepts natively in Swift and adds Apple GameController support.

## License

Stream64 source releases after the license transition are available under the \
**[PolyForm Noncommercial License 1.0.0](LICENSE)**. Personal, educational, \
research, charitable, public-sector, and other noncommercial uses are permitted. \
Commercial use, commercial resale, and incorporating Stream64 into a commercial \
product or service are not permitted without a separate written commercial \
license from the creator.

The required creator attribution is recorded in [NOTICE](NOTICE) and must be \
preserved with every source or binary copy:

> Stream64 Copyright © 2026 Martijn Bosschaart. Stream64 was created by Martijn Bosschaart.

Previously published GPL-3.0 releases remain available under GPL-3.0; their \
already-granted rights are not revoked by this change. Third-party components \
remain governed by their own licenses.

Release history: [CHANGELOG.md](CHANGELOG.md).
