# C64 Ultimate firmware 1.2.1 integration

Included in Stream64 0.140b (build 140).

The official [1.2.1 changelog](https://downloads.commodore-international.com/documentation/changelog-1.2.1.txt) and the OpenAPI document served by the test machine informed these additions. Upstream firmware source can describe features absent from a released build; the device's actual API and menu labels take precedence.

## Features

- Remote mouse joins keyboard and joystick controls. It requires detected **official C64 Ultimate firmware 1.2.1 or newer**, excluding prereleases, and a mouse-capable input endpoint. Movement and wheel reports are coalesced, bounded, and respect firmware queue backpressure. Leaving the viewer, changing focus, disabling input, or disconnecting releases held input.
- Configurable fire2/fire3 keys and gamepad face buttons use the additional port-2 fire inputs.
- Device Controls has separate Audio, Mouse, Software IEC, and Power & Wake tabs. Settings validate against firmware options/ranges and verify by readback. Save to Flash is a separate explicit operation.
- Drive Bay displays Software IEC mode, partitions and last error, supports reset, exposes upload mount modes, and creates DNP images with 1–255 tracks of 64 KiB each. Native partition assignment stays in the firmware menu.
- P00 files are validated, unwrapped for uploaded runs, and display the embedded C64 filename. Commander, drops and archive extraction recognize them.
- Companion CFG profiles can be edited, captured from current settings, saved, optionally copied/moved with a title, and applied when launching. A complete profile is validated before writing; partial failures trigger restoration. No automatic flash saves.
- File operations inspect current mounted images and refuse changes to an image, its contents, or its containing folder. Transfers recheck before destination promotion and moved-source deletion. Firmware offers no atomic mount/file-operation lock, so external clients can still race these checks.
- Offline Wake sends a magic packet to the remembered **Wi-Fi MAC** and starts reconnection. Firmware requires associated Wi-Fi for standby wake; Ethernet cannot wake it.
- Firmware Menu shortcuts navigate observed labels for tape playback, cartridge save and debug log export. Stop pauses a playing tape first because firmware only offers Stop while paused. Save dialogs remain visible for filename entry, and Commander retrieves the resulting files.

## Validation

Automated coverage is in `Firmware121Tests.swift`, `MouseInputTests.swift`, and opt-in `Firmware121LiveTests.swift`, alongside the existing suite. Final validation on 2026-11-18: 316 regression tests after integrating upstream 0.139b, 13 skipped, zero failures; all three opt-in hardware tests passed separately, including the mouse queue-drain assertions. Both arm64 and x86_64 builds succeeded.

```sh
swift test --build-system native
UV_LIVE_FIRMWARE_HOST=172.16.10.64 swift test --build-system native --filter Firmware121LiveTests
```

Live tests create uniquely named temporary files, exercise runtime settings, and restore changed settings and remove their fixtures. They replace the running C64 program and temporarily load a test cartridge; run them on an available development machine with an empty emulated drive. No settings are saved to flash.

Validated on C64 Ultimate 1.2.1, core 1.50, firmware hash `31687dbd`:

- Settings apply/readback/restoration, Software IEC on/off/reset and logging.
- DNP size, read-only disk mount, and rejection of mounted-image deletion.
- P00 upload and remote run verified against C64 memory; CFG save/copy/readback/application.
- Mouse motion, wheel, all three held buttons after queue drain, additional fire inputs, and release/detach state.
- Tape start/pause/resume/stop; EasyFlash cartridge export and downloaded CRT header; nonempty debug-log export/download.
- Native app mouse enable/Escape, device tabs and settings, Drive Bay/DNP controls, and profile editor save/readback.
- Apple Silicon and Intel compilation; automated magic-packet format and actual UDP loopback delivery.

The test machine uses Ethernet only. Actual standby-to-awake behavior is therefore **not hardware-verified**. Manual GEOS testing confirmed pointer movement after selecting COMM 1351. Physical gamepad models and other C64 applications still require application/hardware-specific acceptance; automated input and mapping tests do not establish compatibility with every title or controller.

## GEOS: clicks work but the pointer does not move

GEOS must have its proportional **COMM 1351** input driver loaded. The built-in joystick driver can recognize the mouse's left button as joystick fire while ignoring proportional movement. Use **geos → select input**, choose **COMM 1351**, and confirm **OK**. The keyboard shortcut is Commodore+I (Option+I with Stream64 keyboard capture and the viewer focused). See the original [GEOS input-driver instructions](https://cbmfiles.com/geos/geos-8.php).

During diagnosis, small REST movement reports drained successfully but GEOS's cursor coordinates stayed unchanged. A short port-1 joystick Right input moved its cursor from X=40 to X=78, and the loaded input-driver code read CIA joystick directions rather than SID POT registers. This identifies an active joystick-style driver; an installed or previously chosen 1351 file alone does not establish which driver is currently executing. Do not treat successful API acknowledgement as proof of movement inside GEOS.
