# Changelog

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
