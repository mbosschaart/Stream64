# Changelog

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
