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
    case monitorBezel
    case keyboard
    case files
    case assembly64
    case multiDevice
    case machineControl
    case troubleshooting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .devices: return "Devices & Connection"
        case .viewing: return "Viewing & Full Screen"
        case .rendering: return "Rendering & CRT Simulation"
        case .monitorBezel: return "Monitor Bezel"
        case .keyboard: return "Keyboard Input"
        case .files: return "Loading Files"
        case .assembly64: return "Assembly64 Library"
        case .multiDevice: return "Multiple Devices"
        case .machineControl: return "Machine Control"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    var icon: String {
        switch self {
        case .gettingStarted: return "sparkles"
        case .devices: return "desktopcomputer"
        case .viewing: return "arrow.up.left.and.arrow.down.right"
        case .rendering: return "camera.filters"
        case .monitorBezel: return "tv"
        case .keyboard: return "keyboard"
        case .files: return "arrow.down.doc"
        case .assembly64: return "books.vertical"
        case .multiDevice: return "square.grid.2x2"
        case .machineControl: return "power"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }

    var content: String {
        switch self {
        case .gettingStarted: return Self.gettingStartedText
        case .devices: return Self.devicesText
        case .viewing: return Self.viewingText
        case .rendering: return Self.renderingText
        case .monitorBezel: return Self.monitorBezelText
        case .keyboard: return Self.keyboardText
        case .files: return Self.filesText
        case .assembly64: return Self.assembly64Text
        case .multiDevice: return Self.multiDeviceText
        case .machineControl: return Self.machineControlText
        case .troubleshooting: return Self.troubleshootingText
        }
    }

    // MARK: - Content

    private static let gettingStartedText = """
    Stream64 streams live video and audio from a **Commodore 64 Ultimate** \
    (Ultimate 64, Ultimate 64 Elite, Ultimate-II+) to your Mac over the network, \
    with hardware-accelerated rendering and full remote control.

    **Requirements**

    • Ultimate 64/Elite firmware 3.11+, or C64 Ultimate firmware 1.1+, on the same network
    • The device's data streams reach this Mac over UDP — no firewall blocking inbound UDP

    **First connection**

    1. Click **Add Device…** in the sidebar (or press ⇧⌘N)
    2. Enter a name and the device's IP address or hostname
    3. Click **Test Connection** to verify it's reachable
    4. Click **Add** — the viewer connects automatically when selected

    The app asks the Ultimate to stream video (a 384×272 pixel, ~50 fps PAL \
    picture) and audio (47983 Hz stereo) to your Mac, then renders it with Metal.

    **The toolbar** holds everything for the current stream: connect/disconnect, \
    machine controls (reset, reboot, pause, menu, power), display settings \
    (scaling, filter, input signal, bezel), keyboard capture, and full screen. \
    Everything is also available by **right-clicking the picture**.

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

    **Connection flow**

    When you select a device (with auto-connect on), the app verifies the \
    device over its REST API, opens local UDP listeners, then asks the device \
    to stream to this Mac's address. Stream64 stops requested streams, waits \
    one second for firmware teardown, then starts them. Receiver packet \
    baselines prevent stale traffic from suppressing reconnect. The toolbar \
    subtitle shows product and firmware once connected.

    Only one Stream64 process can run at once. A repeated launch activates the \
    existing window instead of competing for the same UDP ports.

    **Stream duration** (Settings → Network) can auto-stop streams on the \
    device after a fixed time — a safety net if the viewer loses connectivity. \
    Use **Restart Streams** in the toolbar or right-click menu if the picture \
    freezes after the duration expires.
    """

    private static let viewingText = """
    **Scaling modes** (toolbar or right-click → Scaling)

    • **Fit** — largest 4:3 picture that fits the window
    • **Integer** — whole-pixel multiples only, for the sharpest possible image
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
    Rate. Shows the live stream rate (~50 fps for PAL).

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
    • **Composite** — color bleeds horizontally, luma softens, dot crawl on \
    color edges, slight ghosting. The classic single-cable look.
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

    **Picture controls** — with the Commodore 1702 bezel visible, click its \
    front panel to open the door: real VOLUME, BRIGHT, COLOR, TINT, and \
    CONTRAST knobs drive the picture live (drag up/down; double-click to \
    center). These work like the real monitor's pots — color at zero gives a \
    black-and-white picture, tint rotates hues, contrast crushes or flattens. \
    BRIGHT has extended highlight headroom; COLOR rises to extreme 4× chroma \
    at its end stop for intentionally overdriven CRT color.
    """

    private static let monitorBezelText = """
    Show a period-correct monitor around the picture: right-click → Monitor \
    Bezel → Show Bezel, then pick a style.

    • **Commodore 1702** — the classic cream monitor with its dark control \
    strip. Click the strip to flip down the door and reveal **working \
    front-panel knobs** (volume, brightness, color, tint, contrast) that \
    adjust this stream in real time. CRT filters use its coarser **0.64 mm \
    shadow-mask dot pitch**.
    • **Commodore 1084S** — the grey-beige Amiga-era monitor with front \
    buttons, a green power LED, and a finer **0.42 mm dot pitch**.

    **Tube Reflection** (with the CRT Tube filter) renders the picture's own \
    light onto the black mask around the tube face — geometrically correct, \
    so a bright area at the screen edge glows onto the adjacent mask. Toggle \
    it via right-click → Monitor Bezel → Tube Reflection.

    The bezel scales with the window and keeps the tube opening at exactly 4:3.
    """

    private static let keyboardText = """
    Type on your C64 from the Mac keyboard.

    **Keyboard capture** (toolbar keyboard icon, or right-click menu) — when \
    on, keystrokes go to the C64 while the viewer is focused. Click the \
    picture first to give it focus.

    Keys are delivered into the C64's keyboard buffer over the network. \
    Regular text, RETURN, delete, cursor keys, HOME/CLR, and **F1–F8** all \
    work. RUN/STOP is Escape.

    **On-screen keyboard** (toolbar, next to capture) — a full C64-layout \
    keyboard with every key clickable, including SHIFT combinations for \
    PETSCII graphics characters. SHIFT is sticky: click it, then the key.

    **A note on games** — keystrokes arrive through the C64's KERNAL buffer, \
    which BASIC and most utilities read. Games that scan the keyboard \
    hardware directly won't see injected keys; that's a platform limitation, \
    not a setting.

    Keystrokes are flushed automatically when you reset the machine or load \
    a program, so stale input never replays into the next program.
    """

    private static let filesText = """
    **Drag a file onto the picture** to load it on that C64:

    • **.prg** — uploaded and run immediately (reset + load + RUN)
    • **.d64 / .g64 / .d71 / .g71 / .d81** — disk image, mounted in drive A

    The file uploads straight from your Mac — it does not need to exist on \
    the Ultimate's storage. A banner shows upload progress and the result.

    **In the All Screens grid**, drop onto a specific tile to load on that \
    machine.

    **Multi Drop** — hold **⌃ Control** while dropping (anywhere: tile or \
    single view) and the file loads on **every connected device \
    simultaneously**. Perfect for synchronized two-player starts.

    After loading a .d64, type `LOAD"*",8,1` and `RUN` on the C64 (or use \
    the on-screen keyboard) as usual.

    You can also load software directly from the **Assembly64 online \
    library** without downloading anything first — see the Assembly64 \
    Library topic.
    """

    private static let assembly64Text = """
    **Assembly64** is an online library of C64 software — games, demos, \
    music, tools — aggregated from CSDB, GameBase64, HVSC, OneLoad64, tape \
    archives, and more. Stream64 searches it and loads results straight onto \
    your machine, no files touching your Mac.

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

    **Per-device rendering** — filter, input signal, palette, bezel, and the \
    monitor knobs are stored per device. One machine can look like RF on a \
    1702 while another is pixel-sharp.

    **Ports** — each device streams to its own pair of local UDP ports. The \
    Add Device sheet picks free ports automatically; two devices can never \
    share a port.

    In **full screen**, ← and → cycle through your devices.
    """

    private static let machineControlText = """
    All machine controls live in the toolbar and the right-click menu:

    • **Reset C64** — hardware reset, like the button on the machine
    • **Reboot Ultimate** — full device reboot; the app waits for it to come \
    back and restarts the streams automatically
    • **Pause / Resume** — freezes and resumes the machine
    • **Menu** — presses the Ultimate's menu button
    • **Power Off** — powers down the machine (asks for confirmation; \
    configurable in Settings → General)
    • **Restart Streams** — re-arms video/audio to this Mac without a \
    reconnect, for when the picture froze but the device is fine

    **Settings → Audio** — volume (also on the 1702 bezel's VOLUME knob) and \
    the jitter buffer. A larger buffer smooths playback on busy networks at \
    the cost of latency; 60 ms is a good default.
    """

    private static let troubleshootingText = """
    **Black screen after connecting** — use **Restart Streams** (toolbar or \
    right-click). If that fails, check that no firewall blocks inbound UDP \
    on the device's video/audio ports.

    **"Network stack appears stuck" error** — an immediate start after stop can \
    trigger a misleading firmware error. Stream64 uses a proven stop → one \
    second wait → start sequence and retries automatically. If the settled \
    retry still fails, use **Reboot Device & Retry**; a genuinely wedged stack \
    can remain reachable over REST while refusing stream destinations.

    **Choppy or stuttering audio** — raise the jitter buffer in Settings → \
    Audio (try 100 ms). Wi-Fi is the usual culprit; wired Ethernet on either \
    end helps.

    **Keyboard input not arriving** — make sure keyboard capture is on \
    (toolbar) and the picture has focus (click it once). Games that read \
    the keyboard hardware directly can't receive injected keys — see the \
    Keyboard Input topic.

    **Picture judders when the window is in the background** — expected \
    macOS behavior is throttled; the app keeps rendering, but fully covered \
    windows may still skip presentation. Bring the window forward.

    **Two devices, one shows no picture** — both are probably configured \
    with the same local ports. Edit one device and give it a unique \
    video/audio port pair (e.g. 11002/11003).

    **The picture looks wrong after changing filters** — filters and input \
    signal are per device; check you adjusted the device you're looking at \
    (the right-click menu always targets the stream under the pointer).
    """
}
