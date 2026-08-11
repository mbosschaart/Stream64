# Changelog

## 0.110b — 2026-08-11

### Added

- **Piano Keyboard SID visualization** — a per-voice piano (fixed C1–C7) whose keys press and light up to match the tone each SID channel is currently playing. Available from **SID Visualizations** alongside the existing modes (19 total).
- **Audio output device picker** in Settings → Audio — choose which Mac speaker/headphones Stream64 uses locally, independent of the system default and of AirPlay.
- **Drag-and-drop `.sid` and `.crt`** onto the stream (alongside `.prg` and disk images) — SIDs play via the Ultimate's built-in player; cartridges start immediately.

### Improved

- **Integer scaling** falls back to Fit when the largest whole-pixel scale would leave most of the window empty, so awkward fullscreen sizes no longer look tiny.
- **Save Window Layout overwrites** any previously saved per-device arrangement (empty captures no longer clear a good snapshot).
- **Joystick / gamepad input no longer tanks stream display FPS** — successful matrix sends no longer republish input capability on every batch, the live viewer no longer observes high-churn `InputSettings`, and analog stick samples are coalesced with unchanged-axis early-outs.

## 0.109b — 2026-08-11

### Fixed

- **Closing the streaming window now quits the app cleanly.** SwiftUI often detached the main-viewer close observer before `willClose`, and quit waited on remote stream-stop/release calls, so the UI could disappear while audio and the process kept running. Local audio/AirPlay now stop immediately, remote cleanup is time-bounded, and closing the stream window reliably terminates Stream64.

## 0.108b — 2026-08-11

### Fixed

- **Live stream display FPS no longer collapses when SID visualizations and the 3D Memory Map are open.** Secondary views were timer-driven on the main run loop while the CRT path is demand-driven, so SID synthesis and 3D heatmap rebuilds starved Metal presents even though those windows still felt responsive. Display-path pressure is now detected from slow presents (not only GPU semaphore misses); the 3D map rebuilds off the main thread and yields presents under pressure; SID ticks and sample synthesis throttle while the stream is behind.
- **Right-click menus no longer jump or dismiss mid-selection.** Host views that owned `.contextMenu` were observing `DeviceSession` / SID model publishes (fps, present rate, engine ticks), so SwiftUI rebuilt the menu while the user was traversing it. Context menus now sit on non-observing hosts; menu content snapshots state instead of observing live objects; `VideoView` no longer observes the session for fps churn.

### Improved

- **Frame-rate overlay reports `stream / display`** when Metal presents fall behind the UDP receive rate, so heavy secondary visualization load is visible at a glance.
- **SID visualization windows** mirror shared engine data per window (instead of every Canvas observing one shared `SIDEngine`), pause when occluded, and adapt tick rate / sample caps under Open-All style loads.
- **3D Memory Map** peeks heatmap generation cheaply, skips redundant snapshot copies, and prefers the live CRT present path when the display is under pressure.
- Session streaming / debug-trace / audio startup paths gained safer cancellation, generation gates, and bounded mailboxes so recovery work cannot stack against the render loop.

## 0.107b — 2026-08-07

### Changed

- Future Stream64 source and binary releases are licensed under **PolyForm Noncommercial 1.0.0** with mandatory creator attribution. Commercial use and resale require a separate written license. Previously published GPL-3.0 releases retain their original license.

## 0.106b — 2026-08-06

### Changed

- **Software updates now open the GitHub release page** instead of downloading, replacing, or relaunching the app. This keeps updates compatible with the current unsigned distribution workflow.

## 0.105b — 2026-08-06

### Fixed

- Removed stale built-in Help documentation describing the temporarily unavailable 1702/1084S monitor-case presentation and monitor controls.

## 0.104b — 2026-08-06

### Added

- **GitHub update checking.** Stream64 can check the latest stable release at startup or through **Check for Updates…**, with a General Settings opt-out, architecture-matched ZIP downloads, SHA-256 verification, and confirmed automatic replacement/relaunch.

## 0.103b — 2026-08-04

### Added

- **Reliability and recovery hardening across streaming and file operations.** Video, audio, debug-trace, input, session, FTP, Assembly64, persistence, and AirPlay paths now use bounded queues, generation checks, safer teardown, atomic transfer promotion, partial-file cleanup, validated download limits, and corruption recovery.
- **Demand-driven video rendering.** Normal video redraws now occur when frames or settings change; animated RF and power-off effects retain a bounded refresh timer to reduce CPU/GPU use with multiple viewers.

### Fixed

- **SID visualizations could overload the main thread.** Shared SID state now avoids publishing unchanged register data on every timer tick.
- **Opening SID visualizations could crash the app.** Debug-stream source access now detects receiver-queue reentrancy instead of synchronously dispatching onto the same queue.
- **Failed FTP transfers could leave orphaned partial files.** Upload and promotion failure paths now remove temporary remote objects while preserving the original destination.
- **Video frames could stop updating after demand-driven redraw optimization.** Metal view invalidation is now dispatched safely to the main UI thread.

## 0.102b — 2026-08-03

### Added

- **App-wide AirPlay audio output.** A global macOS route picker in the main toolbar and Audio Settings sends whichever C64 is currently audible to one persistent AirPlay destination without changing the Mac's system output. Stream64 converts live 47983 Hz stereo to 48 kHz AAC, serves a bounded tokenized audio-only HLS window over the LAN, and routes it through one shared `AVPlayer`. Once activated, AirPlay remains the output until the user explicitly stops it; typing, view/C64 switching, resets/reboots and temporary source/transport gaps never re-enable local playback. A silence heartbeat keeps the global timeline alive between sources. AirPlay's expected 1–3 second latency is independent of the local jitter-buffer setting.

### Fixed

- **Ordinary app interaction could drop a selected AirPlay route back to the Mac.** SwiftUI was reconstructing toolbar/settings route-picker wrappers and deallocating the native `AVRoutePickerView` that participates in macOS route ownership. The app-wide controller now retains stable picker instances across every view reconstruction; same-source policy updates are idempotent, source gaps emit timed silence, transient route loss retries without enabling local output, and the local `AVAudioEngine` is physically paused for the duration of the AirPlay lock.

## 0.101b — 2026-08-03

### Added

- **Memory Map: Byte Load visualization** — keeps the last byte observed at every address and maps all 256 values (`$00–$FF`) to brightness while retaining green/read and orange/write direction.
- **Memory Map: rotatable 3D Map** — renders the complete 256×256 address matrix as a Metal-instanced terrain: bar height is byte value, color is last read/write direction, drag rotates, scroll/pinch zooms, hover shows address/value/region, and double-click or the toolbar button resets the isometric camera. Adaptive detail, hover inspection, RAM/ROM/I/O region overlays and recent-access pulses are independently toggleable.
- **Fine memory-cell grid and expanded landmarks**, including a bracketed banked Character ROM range and source-specific C64/1541 labels.

### Changed

- **Debug Trace opens its stream automatically** whenever the window opens and no trace is already active; an existing trace shared with SID visualizations is left untouched.
- **Debug Trace window controls moved into the native titlebar toolbar.** The map itself now uses the content area instead of losing a full row to controls; capture/export actions use compact icons, map options live in toolbar menus, and status only occupies a thin strip when needed.
- **Memory Map rendering moved from SwiftUI image publication to a reusable AppKit bitmap/layer surface**, with bounded 20 Hz updates, safe live resizing, better surrounding spacing and labels clamped inside the visible gutter.

### Fixed

- **Read/write colors could be wrong for closely batched accesses.** Direction is now tracked explicitly in bus order instead of inferred from timestamps, so a read immediately turns a just-written orange byte green and read-modify-write sequences resolve correctly.
- **Dragging the decay slider could destabilize compositing and corrupt the main stream.** Decay now uses an isolated native AppKit toolbar control that writes directly to renderer settings without continuously rebuilding the Debug Trace SwiftUI hierarchy.
- **Rotating the 3D map could hang the C64 stream.** Camera events are coalesced to the bounded render cadence, zero-height geometry is omitted, and zoomed-out views aggregate into 2×2/4×4/8×8 blocks to reduce GPU contention.
- **Decay text and read/write legends could become illegible in Light Mode** despite sitting on a forced-black map background; map labels now use explicit high-contrast colors.

## 0.100b — 2026-08-02

### Fixed

- **Every packaged release (DMG and ZIP, both architectures, back to v0.91b) crashed instantly on launch.** A leftover reference to SwiftPM's `Bundle.module` resource-bundle accessor — meant only as a `swift run` fallback — was evaluated unconditionally during branded startup and trapped with a fatal error, since the packaged `.app` never contains the resource bundle it looks for. Startup asset lookup now only ever uses `Bundle.main` in a packaged app. See `HANDOVER.md` §18.
- **Release builds could intermittently fail to sign** with `resource fork, Finder information, or similar detritus not allowed`, because this project's working copy lives in iCloud Drive and the iCloud file-provider daemon could tag the app bundle mid-build. `Scripts/build-release.sh` now assembles and signs the app in a local scratch directory outside iCloud Drive before writing the final `.zip`/`.dmg`/checksum into `dist/`. See `HANDOVER.md` §18.
- **Audio could silently fail to reach a system default output that's a multi-output/aggregate device** (e.g. one combining real speakers with a virtual recording driver), even though normal playback sounded completely correct. `AVAudioEngine`'s automatic device selection could bind directly to one real hardware device inside the multi-output device instead of the multi-output device itself, so anything else relying on that same default output — a separate recording setup, for instance — received nothing. `AudioReceiver` now explicitly pins its output to the current default device and re-pins automatically whenever the audio device configuration changes, instead of trusting the engine to pick correctly on its own. See `HANDOVER.md` §17.

## 0.99b — 2026-08-01

### Added

- **SID Oscilloscope: multiple simultaneous windows** — an "Open in New Window" submenu (in the same toolbar/context menu used to switch modes) spawns a fully independent SID Oscilloscope window already set to a chosen mode, so e.g. an Oscilloscope window and a Spectrum Analyzer window can both be open and updating live at once. Each window's title tracks its own mode live.
- **SID Oscilloscope: 3 more visualization modes**, inspired by classic audio-analysis tools — **Voice Lineup** (every channel as a stacked, time-aligned lane with note-name labels at each onset and alignment guides across simultaneous note changes, in the spirit of Sonic Lineup's multi-track view), **3D Waterfall** (a scrolling wireframe spectrum history in perspective, sndpeek-style), and **3D Bar Field** (the same spectrum history as filled 3D-look bars in a blue/purple/pink/orange palette).
- **Spectrogram: piano-key axis + "fire" color ramp** — the frequency axis is now labeled by note name (C1...C9) instead of raw Hz, and the heatmap uses a black/purple/red/orange/yellow ramp instead of the previous blue/green/yellow/red one.
- **SID Oscilloscope: 7 more visualization modes**, surfacing raw register data no existing mode showed — **VU Meter Bank** (large per-channel level meters with peak-hold, like a real mixing console's meter bridge), **Register Activity Grid** (a heatmap of the SID's own ~25 registers per chip, labeled by mnemonic, lighting up on each write — what the player routine is doing, not the resulting audio), **ADSR Knobs** (the raw Attack/Decay/Sustain/Release register values with their real millisecond times, distinct from the existing envelope-curve mode), **Pulse Width** (a duty-cycle gauge for the 12-bit pulse-width register, surfacing PWM-sweep effects invisible elsewhere), **Control Bits** (an LED-style indicator grid for all 8 control-register bits per channel), **SID Dashboard** (a per-chip summary of active voices, master volume, and filter state), and **Colorful Waveform** (all channels' waveforms overlaid in vibrant colors with a glow, a style showcase).

### Changed

- **Spectrum Analyzer/Spectrogram/3D Waterfall/3D Bar Field: fixed bar scaling.** The fixed "-60...0 dB" range used to normalize FFT bars didn't match the raw (unnormalized) magnitude scale `vDSP_fft_zrip` actually produces, so real audio pegged nearly every bar to full red regardless of how loud the content was. Replaced with an auto-gain (peak-hold-with-slow-release, like an analog VU meter) that scales bars relative to the loudest recent content instead of a fixed absolute level.
- **Same modes: fixed showing fake activity after playback stops.** The Ultimate keeps streaming audio packets continuously whenever the stream is running, whether or not anything is actually playing — auto-gain was rescaling that near-silent residual noise floor up to full brightness. A new absolute silence check (on the real, calibrated sample level, not the FFT's own relative units) now shows empty bars once actual signal drops below a real noise floor, instead of auto-gain making silence look like loud music.
- **"Machine Monitor" renamed to "Ultimate Menu."** In everyday use this Telnet/VT100 window is mostly a live, non-interrupting view of the on-screen menu (not the Machine Code Monitor specifically), which the old name undersold.
- **Ultimate Menu: fixed box borders/side rails rendering as literal letters** ("q"/"x"/"j"/"k" and similar instead of ─/│/┐/┘). These use the standard VT100 DEC Special Graphics line-drawing character set, not PETSCII graphics — now decoded correctly.
- **Ultimate Menu: fixed the window going blank/frozen on some firmware.** A parsing gap meant `ESC[?25l`-style sequences (hiding the cursor, or switching to the alternate screen buffer) ended the escape sequence one byte early and wrote the rest of it onto the screen as literal text — repeated on every cursor blink, this could scroll all real menu content off-screen. The VT100 decoder now follows the real ANSI CSI grammar instead.
- **Ultimate Menu: fixed a handful of stray characters at the very start of every screen** (previously easy to mistake for a small decorative logo). The Ultimate's Telnet server sends genuine Telnet protocol-negotiation bytes before any VT100 content, which weren't being filtered out and got decoded as if they were displayable text.
- **SID Oscilloscope: register-driven modes now start their required debug trace automatically.** Opening the window used to show a banner asking you to click "Start 6510 Trace" if one wasn't already running; it now just starts one silently in the background, with no prompt.
- **SID Oscilloscope: "Open All in Grid"** opens every visualization mode at once, each in its own window, automatically tiled into a grid sized to fit the screen — available from the toolbar/context menu and as its own "SID Oscilloscope — All Modes…" entry on the stream's right-click menu.
- **SID Oscilloscope: reduced lag/overhead in the audio-driven modes.** Incoming audio for Spectrum Analyzer/Lissajous/Spectrogram/3D Waterfall/3D Bar Field is now batched and processed at a steady 30 Hz instead of hopping to the main thread on every individual network packet (~250/second) — this also fixed a secondary cause of "still shows activity after playback stops," since a backlog of not-yet-processed audio could otherwise take a moment to visibly catch up.
- **SID Oscilloscope: fixed "Open All in Grid" briefly hiding the Debug Trace/Ultimate Menu/SID Oscilloscope menu entries.** Opening all 11 windows at once fired all their startup network requests in the same instant, which could overwhelm the device enough to fail an unrelated capability check and hide those menu entries for about a minute until it succeeded again. Each window's startup is now staggered instead of firing all at once.
- **"Open All in Grid" now opens every window at its actual minimum size**, centered on screen, instead of stretching each one to fill an even fraction of the whole display — with 11 modes, that stretching made even simple bar-graph modes needlessly huge.
- **The toolbar's Menu button now opens the Ultimate Menu** instead of pressing the Ultimate's physical menu button — the same non-interrupting behavior as the "Ultimate Menu…" entry already had, just reachable with one click from the toolbar too. The now-redundant "Menu Button" entry was removed from the stream's right-click menu.
- **SID Oscilloscope: fixed stale audio activity lingering after a reset/reboot/power-off.** All modes reconstruct their picture purely from register *writes* seen on the debug trace — a reset doesn't necessarily generate any new writes at all, so a voice that was playing kept "playing" in every mode indefinitely, since nothing ever told the reconstruction otherwise. Resetting, rebooting, or powering off the machine now explicitly clears the Oscilloscope's reconstructed state back to silence.
- **"Open All in Grid" no longer overlaps windows.** Each window's requested size was slightly smaller than its own minimum window size (to leave a gap between them), so macOS silently grew every window back up to its minimum without shrinking the gap to match, leaving neighboring windows overlapping by that amount. The grid's per-window cell is now sized to leave the intended gap without ever requesting a window smaller than its minimum.
- **Save/Restore SID Window Layout.** Arrange the SID Oscilloscope windows however you like (which modes, positions, sizes), then "Save Window Layout" to remember it — persisted per device, so it survives quitting and relaunching the app. "Restore Window Layout" closes whatever SID Oscilloscope windows are currently open and reopens the saved arrangement. Available from the SID Oscilloscope's own toolbar/right-click menu and from the stream's right-click menu (under "SID Window Layout") so it's reachable even with no SID windows currently open.
- **SID Oscilloscope menu restructured: mode selection always opens a new window.** The stream's right-click menu now has a single "SID Visualizations" submenu listing all 18 modes directly (replacing the old flat "SID Oscilloscope…"/"SID Oscilloscope — All Modes…" entries), each opening a brand-new window rather than reusing/switching an existing one. To match, the SID Oscilloscope window itself no longer has a toolbar/pulldown menu for switching its own mode — a window's mode is now fixed for its lifetime — and its right-click context menu's mode list behaves the same "always opens a new window" way instead of changing the current window (its old, now-redundant "Open in New Window" submenu was folded into that same list).
- **SID Oscilloscope: reduced per-window CPU cost, especially noticeable with many windows open.** Each window now only does the work its own mode actually needs: the audio-rate oscillator/envelope stepping loop (by far the most expensive part of every tick) now only runs for the 5 modes that actually read synthesized samples/levels (Oscilloscope, ADSR Envelope, Mixer Console, VU Meter Bank, Colorful Waveform) instead of unconditionally for all 18; the 5 pure-audio modes (Spectrum Analyzer, Lissajous Scope, Spectrogram, 3D Waterfall, 3D Bar Field) no longer fetch the SID configuration, force a debug trace to start, or subscribe to the bus-trace stream at all, since they never look at SID registers. Also fixed a small array being reallocated on every single synthesized sample (up to ~267 times per window per tick) instead of once. Colorful Waveform's always-on glow (previously the single most expensive visualization in the app — 3 blur passes per channel, every frame, with no way to turn it off) now respects the same Phosphor Glow toggle every other mode already had, off by default.
- **SID Oscilloscope: introduced a shared per-device engine, eliminating the remaining cross-window duplication.** Every open SID Oscilloscope window on the same device used to run a fully independent copy of the debug-trace filtering, 8 kHz synthesis, and FFT — two windows both showing register-driven modes simulated identical oscillators twice; two both showing spectrum-derived modes ran identical FFTs on the identical audio twice. A new `SIDEngine` (one per device, shared by every window on it) now does all of that exactly once and publishes the result to however many windows are open — 1 SID-config fetch and 1 timer for 18 windows on one device instead of 18 of each. No visual/behavioral change; this only affects how many times the same underlying work gets done.
- **Lissajous Scope zoomed in.** Real SID output rarely swings anywhere near full scale, so the traced pattern used to only fill a small fraction of the window, leaving most of it as unused black margin. The signal is now amplified before being mapped to screen coordinates (and clamped afterwards, so a genuinely loud signal still stays within the circle) so typical content actually uses the available space.

### Removed

- **SID Oscilloscope: removed the Wiring Diagram mode** — it visualized sync/ring-mod routing but rarely showed anything interesting in practice, since most tunes don't use those flags.

## 0.98b — 2026-08-01

### Added

- **SID Oscilloscope: 8 new visualization modes**, selectable from a toolbar "Visualize" menu and a matching right-click context menu on the window (plus an independent Phosphor Glow overlay toggle in the same menu): **ADSR Envelope** and **Mixer Console** (per-channel grid, reusing the existing register-driven synth data), **Piano Roll** (all channels on one shared pitch axis, from a new ~10 s per-voice note-history buffer), **Wiring Diagram** (per-chip ring-mod/sync connector diagram — visualizes flags the synth already decodes but doesn't fully act on), **Filter Curve** (newly decoded per-chip filter/resonance/mode registers plotted as an approximate frequency response), **Spectrum Analyzer** and **Spectrogram** (real FFT bar graph / scrolling heatmap off the actual post-mix audio via a new `Accelerate`/`vDSP` engine, `SIDSpectrumAnalyzer`), and **Lissajous Scope** (real left-vs-right channel stereo-phase plot).
- `AudioReceiver` gained a multicast sample tap (`addSampleObserver`/`removeSampleObserver`, same pattern as `DebugStreamReceiver`'s trace-entry observers) so multiple visualization windows can read the real decoded audio without affecting live playback.

## 0.97b — 2026-08-01

### Added

- **Debug Trace window** (U64/U64 Elite only) — starts the Ultimate's cycle-accurate 6510/VIC/1541 bus-trace stream, decodes it live into a scrolling table (address, data, R/W, PHI2, signal flags) or a real-time 256×256 memory-map heatmap with a live-adjustable decay slider (last read/write per address flashes green/orange and fades out fast — row = address page, with every notable C64 region (RAM, BASIC/KERNAL ROM, VIC-II, SID, color RAM, both CIAs, cartridge I/O) or, for a 1541 drive trace, its own much smaller memory map (RAM, both VIAs, DOS ROM) labelled in a side gutter so labels never overlap the grid), and exports either the raw capture (compatible with the official `grab_debug.py`/`dump_bus_trace.c`/GtkWave pipeline) or the visible table rows as CSV. Runs alongside video/audio streaming rather than interrupting it — despite Ultimate's docs claiming the debug and video streams are mutually exclusive, live testing against a real U64-II showed all three streaming simultaneously without issue. Trace-source selection (6510/VIC/1541, plus two firmware-3.15 IEC variants) was also verified live and uses the `Data Streams`/`Debug Stream Mode` config item, not the debug register as first assumed.
- **Machine Monitor window** (U64/U64 Elite only) — a VT100 terminal view onto the Ultimate's Telnet server (port 23), the documented remote-control path for the on-device menu system and Machine Code Monitor, which has no REST equivalent. Arrow/function keys drive navigation; `Command+letter` is sent as a best-effort stand-in for the physical `C=` modifier.
- **SID Oscilloscope window** (U64/U64 Elite only) — a live per-voice waveform display for the SID (3 channels, or 6 with a second SID configured — base address and channel count auto-detected from `SID Addressing`/`SID Sockets Configuration`, confirmed live against a real dual-8580 U64-II). Each voice's waveform is reconstructed from register writes seen on a 6510-inclusive debug trace through a small approximate SID emulation core (oscillator shapes, standard-timing-table ADSR, a noise LFSR, approximate ring modulation); shows waveform combination, frequency, nearest note name, and gate state per channel. `DebugStreamReceiver` was refactored to multicast entries/stats to multiple observers so this window and the Debug Trace window can watch the same running trace simultaneously without stealing each other's feed.
- New capability probe (`GET /v1/machine:debugreg`) gates all three new windows to devices that actually implement the U64 debug register — Ultimate-II+ and C64 Ultimate hardware do not, and no longer show the menu entries.
- Devices gained a third local UDP port (Debug Port, default 11002) alongside Video/Audio; new-device port allocation now assigns all three as a collision-free triplet.

## 0.96b — 2026-07-25

### Added

- Capability-probed matrix keyboard input with press/release holds, symbolic/positional/custom keymaps, and safe KERNAL-buffer fallback.
- Virtual joystick mode for Arrow keys plus a configurable keyboard fire button (Backquote by default), along with native macOS game controllers, port switching, deadzone handling, merged input sources, and release-all lifecycle safety.
- Automatic Ultimate DMA/Web service readiness checks and persisted per-device Input settings.
- Capability-probed Ultimate `menu_screen` child window with live 40×25 character/colour rendering and keyboard control, falling back to the existing streamed-menu behavior.
- Assembly64 and Commander Run/Play/Mount/Mount & Run target pickers support any configured machine or simultaneous dispatch to **All Connected C64s**.

### Fixed

- Stream pickup now counts only structurally valid VIC/audio packets, so malformed 46-byte UDP noise cannot make Stream64 skip the real stream-start command.
- Silent-stream diagnostics now explain that Ultimate 64 A/V requires the wired Ethernet interface even when REST remains reachable over Wi-Fi.
- Remote menu rendering now treats printable bytes as literal ASCII and maps only the firmware-defined 0x00–0x13 UI glyphs, eliminating spurious dots and substituted letters.
- Settings now uses an explicit toolbar instead of macOS's stale `TabView` metadata, guaranteeing distinct Display/Input labels; Devices uses a power-plug icon.

## 0.95b — 2026-07-22

### Added

- Commander-style dual-pane file manager where each pane can browse Home/internal/USB Mac volumes or any configured Ultimate, including C64-to-C64 transfers, Space-to-mark batch selection, passive FTP browsing, queued copy/move/rename/delete/mkdir, Finder drag-and-drop, conflict policies, progress/retry/cancel controls, and direct remote run/mount/play actions.

### Fixed

- Commander table selection no longer conflicts with pane activation or folder opening.
- Uploads no longer show a conflict dialog unless a matching destination name exists; stale-listing conflicts now pause the queue and offer Replace, Skip, Keep Both, or Cancel instead of failing. The virtual Ultimate root directs users into an actual storage drive instead of returning FTP 502.
- FTP downloads now preserve Network.framework's final-chunk completion flag instead of issuing an extra receive that fails with POSIX error 96.

## 0.92b — 2026-07-22

### Added

- Bounded, cancellable LAN discovery for Ultimate devices with progressive product/firmware results, one-click guided setup, VPN exclusion, and manual-address fallback.
- Movable non-modal CRT picture-controls window for brightness, color, tint, and contrast whenever the physical monitor case is hidden, including fullscreen and multi-device views.

### Changed

- CRT bezel reflections are 10% brighter.
- Composite and RF inputs add PAL-phase cross-color bleed, producing colored fringes around fine bright text and high-contrast lines.

## 0.91b — 2026-07-22

### Added

- Automatic mid-session health checks and reconnect with exponential backoff.
- Filtered PNG screenshots that reproduce the active Metal pipeline.
- Assembly64 discovery filters, pagination, favorites, recents, saved searches, metadata/CSDB previews, complete-entry ZIP download, and safe archive inspection/extraction.
- Persistent Assembly64 library state and bounded metadata/preview caches.
- Per-device CRT screen colors: Color, Amber, Green, and Black & White.
- Monitor-specific 0.42 mm (1084S) and 0.64 mm (1702) shadow-mask pitch.
- Amber phosphor history with 16-color indexed emission and continuous analog decay.
- Dirty Glass CRT mode with photographic corner material, procedural dust, dark flecks, smudges, mineral residue, and subtle refraction.
- Fullscreen pointer auto-hide after five seconds of inactivity.
- CRT Tube power-off collapse with bright line/dot fade and synthesized voltage-discharge crackle.
- Single-instance process locking to prevent competing UDP listeners.
- Ad-hoc signed arm64/x86_64 app, ZIP, and DMG packaging workflow.
- Native Stream64 app icon, centered standalone versioned launch splash, and branded About window with Retro8BITShop link.
- XCTest coverage for AQL, persistence, archive safety, CSDB parsing, display migration, process locking, and embedded Metal compilation.

### Changed

- Composite has stronger asymmetric chroma bleed, softness, ghosting, and dot crawl.
- RF audio uses two-pole high/low filtering for a smaller 1980s TV-speaker sound.
- Brightness and color controls have extended overdrive ranges.
- C64 Ultimate 1.1 stream startup now uses stop → one-second settle → start.
- Stream pickup requires packet growth from a per-connect baseline.
- Assembly64 uses a compact ten-row result layout and fixed-size metadata panel.
- Device ordering is drag-adjustable and persisted.
- Closing any viewer closes all auxiliary windows and terminates Stream64.
- CRT Tube now composites phosphor emission over an invariant charcoal glass base and models the overlapping bezel wall at 85° with non-branching rough-plastic reflection diffusion.
- Monitor case rims are thicker and style-specific: 7.5% for the 1702 and 6.8% for the 1084S.

### Fixed

- Assembly64 search no longer fails on API rows with missing names; malformed rows lacking essential identity are skipped individually.
- Closing a toolbar picker no longer terminates the app; shutdown observes only concrete main viewer windows.
- HTTP 2xx responses with non-empty Ultimate `errors` arrays are treated as failures.
- Stale receiver counters no longer suppress stream startup after reconnect.
- Duplicate app processes can no longer split UDP delivery.
- RF interference sweeps complete before the renderer time loop resets.
- Assembly64 columns and window sizing no longer jump after selection.
- Filtered screenshots include CRT effects, phosphor color, afterglow, and dirty glass.
