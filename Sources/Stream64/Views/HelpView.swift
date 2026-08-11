import SwiftUI

/// In-app documentation: a Help window with a topic sidebar and rich text
/// content. Content lives here as markdown so it ships with the app and
/// works offline.
struct HelpView: View {
    @State private var selectedTopic: HelpTopic? = .gettingStarted

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $selectedTopic) { topic in
                Label(topic.title, systemImage: topic.icon)
                    .tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            if let topic = selectedTopic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(topic.title)
                            .font(.largeTitle.weight(.bold))
                            .padding(.bottom, 12)
                        Text(.init(topic.content))
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: 640, alignment: .leading)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select a Topic", systemImage: "book")
            }
        }
        .navigationTitle("Stream64 Help")
        .frame(minWidth: 760, minHeight: 520)
    }
}

enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted
    case devices
    case viewing
    case rendering
    case keyboard
    case files
    case fileManager
    case assembly64
    case multiDevice
    case machineControl
    case debugAndSID
    case troubleshooting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .devices: return "Devices & Connection"
        case .viewing: return "Viewing & Full Screen"
        case .rendering: return "Rendering & CRT Simulation"
        case .keyboard: return "Keyboard Input"
        case .files: return "Loading Files"
        case .fileManager: return "Commander File Manager"
        case .assembly64: return "Assembly64 Library"
        case .multiDevice: return "Multiple Devices"
        case .machineControl: return "Machine Control"
        case .debugAndSID: return "Debug Trace & SID Oscilloscope"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    var icon: String {
        switch self {
        case .gettingStarted: return "sparkles"
        case .devices: return "desktopcomputer"
        case .viewing: return "arrow.up.left.and.arrow.down.right"
        case .rendering: return "camera.filters"
        case .keyboard: return "keyboard"
        case .files: return "arrow.down.doc"
        case .fileManager: return "rectangle.split.2x1"
        case .assembly64: return "books.vertical"
        case .multiDevice: return "square.grid.2x2"
        case .machineControl: return "power"
        case .debugAndSID: return "waveform.path.ecg"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }

    var content: String {
        switch self {
        case .gettingStarted: return Self.gettingStartedText
        case .devices: return Self.devicesText
        case .viewing: return Self.viewingText
        case .rendering: return Self.renderingText
        case .keyboard: return Self.keyboardText
        case .files: return Self.filesText
        case .fileManager: return Self.fileManagerText
        case .assembly64: return Self.assembly64Text
        case .multiDevice: return Self.multiDeviceText
        case .machineControl: return Self.machineControlText
        case .debugAndSID: return Self.debugAndSIDText
        case .troubleshooting: return Self.troubleshootingText
        }
    }

    // MARK: - Content

    private static let gettingStartedText = """
    **Version \(Stream64Version.display)**

    Stream64 streams live video and audio from a **Commodore 64 Ultimate** \
    (Ultimate 64, Ultimate 64 Elite, Ultimate-II+) to your Mac over the network, \
    with hardware-accelerated rendering and full remote control.

    **Requirements**

    • Ultimate 64/Elite firmware 3.11+, or C64 Ultimate firmware 1.1+, on the same network
    • The device's data streams reach this Mac over UDP — no firewall blocking inbound UDP

    **First connection**

    1. Click **Add Device…** in the sidebar (or press ⇧⌘N)
    2. Stream64 scans active local Ethernet and Wi-Fi networks for Ultimates
    3. Click **Use** beside a discovered device, then **Add**

    Product, firmware, hostname and address are filled in automatically, along \
    with an unused pair of local streaming ports. If discovery finds nothing — \
    for example, when the API is password-protected — manually enter the \
    address and optional password, then click **Test Connection** and **Add**.

    The app asks the Ultimate to stream video (a 384×272 pixel, ~50 fps PAL \
    picture) and audio (47983 Hz stereo) to your Mac, then renders it with Metal.

    **The toolbar** holds everything for the current stream: connect/disconnect, \
    machine controls (reset, reboot, pause, menu, power), display settings \
    (scaling, filter, input signal), keyboard capture, and full screen. \
    Right-clicking the picture provides stream, machine and display controls; \
    the toolbar additionally provides the on-screen keyboard, Assembly64, \
    screenshots and fullscreen.

    To find something to run, open the **Assembly64 browser** (⇧⌘F) and \
    search the online C64 library — results load straight onto the machine.
    """

    private static let devicesText = """
    Devices are managed in the sidebar or in **Settings → Devices**.

    **Adding a device**

    Each device needs its address and, if configured on the device, its API \
    password. The **video/audio ports** are local UDP ports on this Mac where \
    the streams arrive — each device must use its own pair. The app suggests \
    free ports automatically when adding a device.

    Devices can be reordered by dragging rows in the sidebar. Defaults avoid \
    port collisions, but manual edits are not collision-validated.

    **Connection flow**

    When you select a device (with auto-connect on), the app verifies the \
    device over its REST API, opens local UDP listeners, then asks the device \
    to stream to this Mac's address. Stream64 stops requested streams, waits \
    one second for firmware teardown, then starts them. Receiver packet \
    baselines prevent stale traffic from suppressing reconnect. The toolbar \
    subtitle shows product and firmware once connected.

    Only one Stream64 process can run at once. A repeated launch activates the \
    existing window instead of competing for the same UDP ports.

    With **Reconnect automatically** enabled in Settings → General, two failed \
    five-second health checks trigger reconnect attempts with backoff up to \
    30 seconds. Manual Disconnect cancels that loop.

    **Stream duration** (Settings → Network) can auto-stop streams on the \
    device after a fixed time — a safety net if the viewer loses connectivity. \
    Use **Start Streaming** in the toolbar or right-click menu if the picture \
    freezes after the duration expires.
    """

    private static let viewingText = """
    **Scaling modes** (toolbar or right-click → Scaling)

    • **Fit** — largest 4:3 picture that fits the window
    • **Integer** — whole-pixel multiples for the sharpest image; if the \
    largest whole-pixel size would leave most of the window empty, Stream64 \
    temporarily uses Fit instead so fullscreen does not look tiny
    • **Fill** — stretches to fill the window

    The picture always renders at the authentic **4:3 aspect ratio** in Fit and \
    Integer modes, exactly as a real C64 appears on a television.

    **Full screen**

    Press ⌃⌘F (or the toolbar button). All interface chrome disappears — pure \
    picture on black. Move the pointer to the top of the screen for the menu \
    bar, or press ⌃⌘F again to exit. The pointer hides after five seconds \
    without mouse movement and appears immediately when you move the mouse.

    With multiple devices configured, **← and → switch between streams** in \
    full screen, like changing channels. (The arrows pass through to the C64 \
    as cursor keys when only one device is configured.)

    **Frame rate overlay** — enable per device via right-click → Show Frame \
    Rate. Shows the live UDP stream receive rate (~50 fps for PAL). When the \
    display path falls behind under heavy SID / Debug Trace load, a second \
    number appears (`stream / display`) for Metal presents per second.

    **Screenshot** — the toolbar camera, right-click → Save Screenshot…, or \
    ⇧⌘S saves the actual filtered Metal output as PNG, including signal \
    artifacts, CRT curvature, phosphor color/afterglow, reflection and dirt.
    """

    private static let renderingText = """
    Rendering is configured **per device** — each stream remembers its own look.

    **Filters** (right-click → Filter)

    • **Sharp** — pixel-perfect nearest-neighbor. The cleanest image.
    • **Smooth** — bilinear filtering, softer edges.
    • **CRT** — scanlines, phosphor mask, and bloom on a flat screen.
    • **CRT Tube** — everything CRT has, plus curved glass, rounded corners, \
    vignette, and a live reflection of the picture on the black mask around \
    the tube face.

    **Input signal** (CRT filters only, right-click → Input Signal)

    Simulates how the C64 reached the screen:

    • **S-Video** — the clean signal; separated luma and chroma.
    • **Composite** — color bleeds horizontally, fine bright text develops \
    red/green/blue edge fringes from luma-to-chroma crosstalk, luma softens, \
    and color edges show dot crawl and slight ghosting. The classic \
    single-cable look.
    • **RF (antenna)** — composite degraded further: snow, per-line jitter, a \
    drifting interference line, stronger ghosting — plus matching **audio**: \
    mono, band-limited like a small TV speaker, with static and mains hum.

    **Screen color** (CRT filters only) — **Color** preserves the C64 palette; \
    **Amber**, **Green**, and **Black & White** convert the decoded picture to \
    luminance and emulate those physical CRT phosphors. The same color is \
    reflected onto the curved tube mask. Amber has long phosphor persistence: \
    bright moving objects leave decaying golden trails for roughly 240 ms.

    **Dirty Glass** (CRT filters only) — simulates a tube that has not been \
    cleaned in years: photographic corner lint plus uneven grime film, fixed \
    dust motes, isolated dark flecks, separated fingerprint/palm smears, tiny \
    moisture/mineral deposits, warm haze, contrast loss, and subtle refraction \
    of the picture underneath.

    **Palette** — Pepto (default), Colodore, or VICE color tables.

    **Picture controls** — when a CRT filter is active, use the toolbar sliders \
    button or right-click → **Picture Controls…** to open the \
    same brightness, color, tint, and contrast controls in a movable floating \
    window. The viewer stays bright and interactive while it is open. This is \
    also available from the right-click menu in fullscreen and grid views. \
    These work like the real monitor's pots — color at zero gives a \
    black-and-white picture, tint rotates hues, contrast crushes or flattens. \
    BRIGHT has extended highlight headroom; COLOR rises to extreme 4× chroma \
    at its end stop for intentionally overdriven CRT color.
    """

    private static let keyboardText = """
    Type on your C64 from the Mac keyboard.

    **Keyboard capture** (toolbar keyboard icon, or right-click menu) — when \
    on, keystrokes go to the C64 while the viewer is focused. Click the \
    picture first to give it focus.

    In **Auto** mode, supported firmware receives physical matrix press/release \
    events, so held keys and games that scan CIA keyboard hardware work. Older \
    firmware automatically falls back to ordered KERNAL-buffer typing. Regular \
    text, RETURN, delete, cursor keys, HOME/CLR, and **F1–F8** work; RUN/STOP \
    is Escape. Select Symbolic mapping for typed characters or Positional \
    mapping to mirror the physical C64 layout and its held modifiers.

    **On-screen keyboard** (toolbar, next to capture) — a full C64-layout \
    keyboard routed through the same matrix/fallback controller, including \
    SHIFT combinations for PETSCII graphics characters. SHIFT is sticky: click \
    it, then the key. CTRL and RESTORE remain disabled on legacy firmware.

    **Virtual joystick** — press F10 to toggle joystick mode and F11 to switch \
    port 1/2. Arrow keys drive directions; Backquote (`) is the default fire \
    key and can be changed under Settings → Input. Connected macOS \
    game controllers use their D-pad/left stick and primary button. Input is \
    held until key/button release and always released on focus loss or device \
    switching. This requires firmware with `/v1/machine:input` support \
    (public guidance currently says Ultimate 64 firmware 3.15+); unsupported \
    firmware still types through the KERNAL fallback but cannot emulate a \
    hardware joystick.

    Stream64 automatically enables and saves the Ultimate DMA service when \
    REST access is available. Web Remote Control must already be enabled for \
    Stream64 to reach the configuration API.

    All held keyboard and joystick state is released automatically on focus \
    loss, disconnect, reset, device switch, controller removal, and app exit.
    """

    private static let filesText = """
    **Drag a file onto the picture** to load it on that C64:

    • **.prg** — uploaded and run immediately (reset + load + RUN)
    • **.d64 / .g64 / .d71 / .g71 / .d81** — disk image, mounted in drive A
    • **.sid** — played with the Ultimate's built-in SID player
    • **.crt** — started as a cartridge

    The file uploads straight from your Mac — it does not need to exist on \
    the Ultimate's storage. A banner shows upload progress and the result.

    **In the All Screens grid**, drop onto a specific tile to load on that \
    machine.

    **Multi Drop** — hold **⌃ Control** while dropping (anywhere: tile or \
    single view) and the file loads on **every connected device \
    simultaneously**. Perfect for synchronized two-player starts.

    After loading a supported disk image (.d64/.g64/.d71/.g71/.d81), type \
    `LOAD"*",8,1` and `RUN` on the C64 (or use the on-screen keyboard) as usual.

    You can also load software directly from the **Assembly64 online \
    library** without downloading anything first — see the Assembly64 \
    Library topic.
    """

    private static let fileManagerText = """
    Open **File Manager…** from the toolbar or press ⇧⌘B. It uses a two-pane \
    Commander layout: each side can independently browse this Mac or any \
    configured Ultimate, enabling Mac-to-C64 and direct C64-to-C64 transfers.

    **Navigation** — choose Local Mac or a named Ultimate above either pane. \
    Local panes include a **Volumes** menu containing Home, internal volumes, \
    and currently mounted USB drives. Enter a path directly, double-click a \
    folder (or select it and use \
    **Open**/Return), or use Up and Refresh. The \
    Ultimate root is listed dynamically and commonly contains Flash, SD, Temp, \
    USB0, and USB1 depending on attached media. The top-level `/` is only a \
    drive list: open one of those storage roots before uploading or creating \
    folders.

    **Commander keys and buttons**

    • **F2** Rename
    • **F5** Copy to the opposite pane
    • **F6** Move to the opposite pane
    • **F7** Create folder
    • **F8** Delete

    Use the arrow keys to move the table cursor and press **Space** to mark or \
    unmark files. The cursor advances automatically, so a batch can be marked \
    quickly without holding Command. You can also click the checkbox beside \
    any file or folder to build the same multi-selection with the mouse. \
    F5/F6 and the context menu operate on all marked files; **Clear Marks** \
    resets the batch.

    Right-click any selected file or folder for the same Open, Rename, Copy, \
    Move, New Folder, Delete, Run/Play, Mount, and Mount & Run commands. \
    Commands that do not apply to the selection are hidden or disabled.

    Multiple files and complete folders can be selected. Finder files can be \
    dropped into either pane; remote files can be dragged back to Finder. The \
    persistent queue runs one operation at a time, reports progress, and \
    supports pause, cancel, retry, reordering, and clearing completed work.

    **Run / Mount / Play** acts on PRG, disk, SID, MOD, and CRT files. Remote \
    files run directly by their Ultimate path instead of downloading and \
    uploading them again. Disk images also offer **Mount & Run**. Use the \
    toolbar target picker to choose one configured machine or **All Connected \
    C64s**; multi-target actions read the source once and dispatch to every \
    connected session simultaneously.

    The Ultimate's **FTP File Service** must be enabled. Configure its port or \
    username under the device settings if necessary. FTP is unencrypted and \
    intended only for a trusted local network.
    """

    private static let assembly64Text = """
    **Assembly64** is an online library of C64 software — games, demos, \
    music, tools — aggregated from CSDB, GameBase64, HVSC, OneLoad64, tape \
    archives, and more. Stream64 searches it and loads results straight onto \
    your machine without permanent local files. **Save ZIP…** intentionally \
    writes locally, and archive inspection uses a temporary URLSession download.

    The toolbar **Target** picker selects any configured machine or **All \
    Connected C64s**. Run, Play, Mount, and Mount & Run download once and then \
    execute concurrently on every chosen connected machine.

    **Open the browser** — the toolbar's Assembly64 button (books icon), \
    **File → Search Assembly64…**, or ⇧⌘F. It's a separate window, so you \
    can browse while watching the stream.

    **Searching**

    Type a name and press Return. Multi-word names are fine ("last ninja"). \
    A search can also be driven entirely by filters: repository, file type, \
    year, minimum rating, recently updated, sort field, and sort order. The \
    category picker narrows to CSDB demos, GameBase64 games, HVSC music, and \
    more. Use **Load More** when a query has over 200 matches.

    **Your library**

    Star any result to keep it under **Favorites**. Selecting an item adds it \
    to **Recent**. The bookmark menu saves the current text, category, and \
    filters as a named search. Favorites, history, saved searches, metadata \
    previews, and remembered disk actions persist between launches.

    **Loading**

    Select a result to see its metadata, preview/source link when available, \
    and every file in the entry. If Assembly64 has no preview for a CSDB \
    release, Stream64 asks CSDB directly. **Save ZIP…** downloads the complete \
    entry for local archiving. **Inspect ZIP…** safely lists its members and \
    lets you run one supported file without extracting paths onto your Mac. \
    Each file offers actions for its type:

    • **Disk images** (.d64/.g64/.d71/.g71/.d81) — **Mount & Run** mounts \
    the disk, resets the C64, and auto-types `LOAD"*",8,1` + `RUN`; \
    **Mount** just inserts the disk in drive A
    • **.prg** — **Run**: uploaded and started immediately
    • **.sid** — **Play**: sent to the Ultimate's built-in SID player
    • **.crt** — **Run**: started as a cartridge

    Files load onto the **selected device** — shown in the status bar at the \
    bottom of the browser. Multi-disk items (side A/B) list every disk; mount \
    side B when the game asks for it. Stream64 remembers whether you last used \
    **Mount** or **Mount & Run** as quiet history beside the file size; both \
    buttons always keep the same neutral appearance.
    """

    private static let multiDeviceText = """
    Stream64 handles multiple C64 Ultimates at once — each with its own \
    stream, rendering settings, and controls.

    **All Screens grid** — with more than one device configured, a grid \
    button appears in the toolbar. Every device renders live side by side:

    • **Click** a tile to select it — selection controls which device is \
    audible (exactly one plays audio at a time; the others keep streaming, \
    muted)
    • **Double-click** a tile to open it in single view
    • **Right-click** a tile for that device's full control menu
    • **Drop files** on a tile to load on that machine (⌃ = all machines)

    **Per-device rendering** — filter, input signal, and palette are stored per \
    device. One machine can look like RF while another is pixel-sharp.

    **Ports** — each device uses its own local UDP stream ports. The Add Device \
    sheet picks free defaults automatically, and manual edits are validated for \
    valid ranges and collisions.

    In **full screen**, ← and → cycle through your devices.
    """

    private static let machineControlText = """
    All machine controls live in the toolbar and the right-click menu:

    • **Reset C64** — hardware reset, like the button on the machine
    • **Reboot Ultimate** — full device reboot; the app waits for it to come \
    back and restarts the streams automatically
    • **Pause / Resume** — freezes and resumes the machine
    • **Menu** — on firmware with `GET /v1/machine:menu_screen`, Stream64 \
    immediately opens the firmware menu and its live 40×25 character/colour \
    child window. Arrow keys and Return control it; Escape or Close exits. \
    Older firmware keeps the original behavior and shows the menu only inside \
    the normal video stream.
    • **Power Off** — powers down the machine (asks for confirmation; \
    configurable in Settings → General). In CRT Tube mode, the last frame \
    flares, collapses to a horizontal line and center dot, then fades with a \
    synchronized electrical pop/crackle before Stream64 disconnects.
    • **Stop Streaming** — stops video/audio while leaving REST control alive
    • **Start Streaming** — re-arms video/audio to this Mac without a \
    reconnect, for when the picture froze but the device is fine

    Closing any main viewer window fully quits Stream64 and closes every \
    Assembly64, Help, Settings and additional viewer window.

    **Settings → Audio** — choose the Mac output device for local playback, \
    volume, and the jitter buffer. A larger buffer \
    smooths playback on busy networks at \
    the cost of latency; 60 ms is a good default.

    **AirPlay** — use the AirPlay button in the main toolbar or Audio \
    Settings to send the currently selected C64's audio to a receiver. This \
    is one app-wide route: selecting another C64 changes the source without \
    changing the AirPlay destination. Local output remains low-latency; \
    AirPlay normally adds around 1–3 seconds of buffering. Once activated, \
    the app stays locked to AirPlay through typing, view changes, C64 \
    switching and reset/reboot; temporary gaps show **Connecting…** rather \
    than enabling local playback. Choose **This Mac** to stop AirPlay.
    """

    private static let debugAndSIDText = """
    Three more windows expose debug facilities specific to the **Ultimate 64 \
    and Ultimate 64 Elite**. All three are hidden automatically on hardware \
    that doesn't support them (Ultimate-II+, C64 Ultimate).

    **Debug Trace** — stream's right-click menu → **Debug Trace…**

    Streams the Ultimate's cycle-accurate 6510, VIC, or 1541-drive bus trace \
    and decodes it live into a scrolling table or — the default — a \
    **Memory Map** with three toolbar-selectable views: **I/O Fade** shows \
    recent reads/writes fading over an adjustable interval; **Byte Load** \
    keeps the last observed byte at every address and maps `$00–$FF` to \
    brightness; **3D Map** renders the same 256×256 address matrix as a \
    rotatable, zoomable terrain whose bar heights are byte values. Drag to \
    rotate, scroll or pinch to zoom, hover for address/value/region details, \
    and double-click to reset the camera. Adaptive detail, hover inspection, \
    region overlays and recent-access pulses can each be switched on or off \
    under **3D Options**. Runs alongside video/audio streaming without \
    interrupting either; the 3D renderer coalesces camera redraws and omits \
    zero-height geometry to avoid starving the main C64 renderer. Both raw \
    capture and visible table rows can be exported.

    **Ultimate Menu** — toolbar Menu button, or the right-click menu

    A live, non-interrupting view of the Ultimate's on-screen menu system \
    (and, if navigated there, the Machine Code Monitor) over the Ultimate's \
    own Telnet server. Unlike pressing the physical menu button, this \
    doesn't pause whatever's running on the C64. Arrow and function keys \
    navigate it normally; **⌘+letter** sends a best-effort stand-in for the \
    physical **C=** modifier key.

    **SID Oscilloscope** — right-click menu → **SID Visualizations**

    A 19-mode SID visualizer — 3 channels normally, 6 when a second SID is \
    configured. Pick any mode from **SID Visualizations** to open it in its \
    own window; any number of modes can be open side by side, or use \
    **Open All in Grid** to open every mode at once, automatically tiled to \
    fit the screen. However your windows end up arranged, **Save Window \
    Layout** remembers it per device (overwriting any previously saved \
    arrangement), so **Restore Window Layout** can bring it back later — \
    even after quitting and relaunching the app. Both are also on the \
    right-click menu, so restoring works even with no SID windows currently \
    open.

    A window's mode is fixed once it's open — picking a different mode from \
    either menu always opens a *new* window rather than switching the \
    current one, so e.g. an Oscilloscope window and a Spectrum Analyzer \
    window can both stay open and updating live side by side.

    Fourteen modes reconstruct their picture from SID register *writes*, \
    seen automatically on a 6510 Debug Trace: **Oscilloscope**, **ADSR \
    Envelope**, **Mixer Console**, **Piano Roll**, **Piano Keyboard**, \
    **Voice Lineup**, **Filter Curve**, **VU Meter Bank**, **Register \
    Activity Grid**, **ADSR Knobs**, **Pulse Width**, **Control Bits**, \
    **SID Dashboard**, and **Colorful Waveform**. Five instead read the \
    real post-mix Ultimate audio stream — **Spectrum Analyzer**, \
    **Lissajous Scope**, **Spectrogram**, **3D Waterfall**, and \
    **3D Bar Field** — so they reflect genuine SID output, including real \
    filter behavior the register-driven modes only approximate. A \
    **Phosphor Glow** toggle (each window's right-click menu) adds a \
    CRT-bloom overlay to whichever mode that window is showing.
    """

    private static let troubleshootingText = """
    **Black screen after connecting** — use **Start Streaming** (toolbar or \
    right-click). If that fails, check that no firewall blocks inbound UDP \
    on the device's video/audio ports.

    **REST works but an Ultimate 64 sends no video/audio** — its Wi-Fi and \
    Ethernet addresses can expose the same REST identity, but A/V streaming \
    uses wired Ethernet. Check the cable and configure the wired DHCP address.

    **"Network stack appears stuck" error** — an immediate start after stop can \
    trigger a misleading firmware error. Stream64 uses a proven stop → one \
    second wait → start sequence and retries automatically. If the settled \
    retry still fails, use **Reboot Device & Retry**; a genuinely wedged stack \
    can remain reachable over REST while refusing stream destinations.

    **Choppy or stuttering audio** — raise the jitter buffer in Settings → \
    Audio (try 100 ms). Wi-Fi is the usual culprit; wired Ethernet on either \
    end helps.

    **Keyboard input not arriving** — make sure keyboard capture is on \
    (toolbar) and the picture has focus (click it once). Check Settings → \
    Input for matrix capability or legacy fallback. Joystick and held-game-key \
    input require firmware that supports `/v1/machine:input`.

    **Picture judders when the window is in the background** — expected \
    macOS behavior is throttled; the app keeps rendering, but fully covered \
    windows may still skip presentation. Bring the window forward.

    **Stream fps drops with SID windows or the 3D Memory Map open** — enable \
    Show Frame Rate; if you see `stream / display`, the picture path is \
    yielding time to those visualizations. Closing unused SID windows or the \
    Debug Trace map usually restores a full display rate. Occluded SID \
    windows pause automatically.

    **Closing the stream window** quits Stream64 entirely (including SID / \
    Debug Trace windows) and stops local audio immediately.

    **Two devices, one shows no picture** — both are probably configured \
    with the same local ports. Edit one device and give it a unique \
    video/audio port pair (e.g. 11002/11003).

    **The picture looks wrong after changing filters** — filters and input \
    signal are per device; check you adjusted the device you're looking at \
    (the right-click menu always targets the stream under the pointer).
    """
}
