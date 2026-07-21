import SwiftUI

/// Decorative monitor bezel drawn around the video. The video content is
/// passed in so the bezel can hold it in its 4:3 "tube" opening.
struct MonitorBezelView<Content: View>: View {
    let style: BezelChoice
    /// Per-device display settings the knobs drive.
    @ObservedObject var display: DisplaySettings
    /// For live volume while a knob turns (bypassing settings publishes).
    var session: DeviceSession?
    @ViewBuilder let content: () -> Content
    @EnvironmentObject var settings: AppSettings
    /// The 1702's flip-down control door: closed shows the wordmark cover,
    /// open reveals the working knobs.
    @State private var doorOpen = false

    // Proportions relative to the tube opening (4:3).
    private var chin: CGFloat { style == .c1702 ? 0.16 : 0.14 }   // control strip below tube
    private var rim: CGFloat {
        style == .c1702 ? 0.075 : 0.068
    }                                                             // case border around tube

    var body: some View {
        GeometryReader { geo in
            // Fit case (tube + rim + chin) into the available space,
            // keeping the tube itself 4:3.
            let tubeAspect: CGFloat = 4.0 / 3.0
            let caseAspectW = tubeAspect + 2 * rim
            let caseAspectH = 1.0 + 2 * rim + chin
            let scale = min(geo.size.width / caseAspectW, geo.size.height / caseAspectH)
            let caseW = caseAspectW * scale
            let caseH = caseAspectH * scale
            let tubeW = tubeAspect * scale
            let tubeH = scale
            let rimPx = rim * scale
            let chinPx = chin * scale

            ZStack {
                // Case body
                RoundedRectangle(cornerRadius: rimPx * 0.9)
                    .fill(caseGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: rimPx * 0.9)
                            .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: rimPx * 0.5, y: rimPx * 0.25)
                    .frame(width: caseW, height: caseH)

                VStack(spacing: 0) {
                    // Tube opening: inset dark surround with the video inside.
                    // The reflection on the sunken mask is rendered by the
                    // CRT tube shader inside the video itself, where the
                    // black mask around the picture actually lives.
                    ZStack {
                        RoundedRectangle(cornerRadius: rimPx * 0.5)
                            .fill(Color(white: 0.06))
                            .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                        content()
                            .clipShape(RoundedRectangle(cornerRadius: rimPx * 0.4))
                            .padding(rimPx * 0.12)
                    }
                    .frame(width: tubeW, height: tubeH)
                    .padding(.top, rimPx)

                    // Control strip
                    controlStrip(width: tubeW, height: chinPx)
                        .frame(width: tubeW, height: chinPx)
                }
                .frame(width: caseW, height: caseH, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// A front-panel rotary pot: drag up/down (or scroll) to turn.
    /// Double-click recenters. Sweep is 270°, 7 o'clock to 5 o'clock.
    /// `live` runs every drag tick outside SwiftUI state; `commit` persists
    /// the value once when the drag ends.
    private func knob(_ label: String, height: CGFloat,
                      initial: Double,
                      live: @escaping (Double) -> Void,
                      commit: @escaping (Double) -> Void) -> some View {
        let size = height * 0.42
        return VStack(spacing: height * 0.06) {
            KnobDial(initial: initial, live: live, commit: commit)
                .frame(width: size, height: size)
            Text(label)
                .font(.system(size: height * 0.13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.72, green: 0.68, blue: 0.60))
        }
    }

    private var caseGradient: LinearGradient {
        switch style {
        case .c1702:
            // Warm cream/beige of the 1702.
            return LinearGradient(
                colors: [Color(red: 0.87, green: 0.84, blue: 0.75),
                         Color(red: 0.80, green: 0.76, blue: 0.66)],
                startPoint: .top, endPoint: .bottom)
        case .c1084:
            // Cooler grey-beige of the 1084S.
            return LinearGradient(
                colors: [Color(red: 0.82, green: 0.81, blue: 0.77),
                         Color(red: 0.74, green: 0.73, blue: 0.69)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private func controlStrip(width: CGFloat, height: CGFloat) -> some View {
        switch style {
        case .c1702:
            // The 1702's hinged control-panel door: closed it's the brown
            // strip with the wordmark; click to flip it down and reveal the
            // working front-panel pots.
            ZStack {
                RoundedRectangle(cornerRadius: height * 0.15)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.28, green: 0.23, blue: 0.19),
                                 Color(red: 0.20, green: 0.16, blue: 0.13)],
                        startPoint: .top, endPoint: .bottom))
                    .padding(.vertical, height * 0.12)

                if doorOpen {
                    HStack(spacing: width * 0.035) {
                        knob("VOLUME", height: height,
                             initial: settings.volume,
                             live: { [weak session] v in session?.audioReceiver.volume = Float(v) },
                             commit: { settings.volume = $0 })
                        knob("BRIGHT", height: height,
                             initial: display.monBrightness,
                             live: { display.picture.brightness = Float($0) },
                             commit: { display.monBrightness = $0 })
                        knob("COLOR", height: height,
                             initial: display.monColor,
                             live: { display.picture.saturation = Float($0) },
                             commit: { display.monColor = $0 })
                        knob("TINT", height: height,
                             initial: display.monTint,
                             live: { display.picture.tint = Float($0) },
                             commit: { display.monTint = $0 })
                        knob("CONTRAST", height: height,
                             initial: display.monContrast,
                             live: { display.picture.contrast = Float($0) },
                             commit: { display.monContrast = $0 })
                        Spacer()
                        Circle() // power LED
                            .fill(Color.red)
                            .frame(width: height * 0.14, height: height * 0.14)
                            .shadow(color: .red, radius: height * 0.08)
                    }
                    .padding(.horizontal, width * 0.05)
                } else {
                    HStack {
                        Text("commodore")
                            .font(.system(size: height * 0.30, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 0.75))
                        Text("1702")
                            .font(.system(size: height * 0.26, weight: .regular, design: .rounded))
                            .foregroundStyle(Color(red: 0.65, green: 0.61, blue: 0.54))
                        Spacer()
                        Circle() // power LED
                            .fill(Color.red)
                            .frame(width: height * 0.14, height: height * 0.14)
                            .shadow(color: .red, radius: height * 0.08)
                    }
                    .padding(.horizontal, width * 0.05)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { doorOpen.toggle() }
            }
            .help(doorOpen ? "Click the panel to close the control door"
                           : "Click the panel to open the control door")
        case .c1084:
            // Flat strip with wordmark, button row, and a green LED.
            ZStack {
                HStack {
                    Text("commodore")
                        .font(.system(size: height * 0.30, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.35))
                    Text("1084S")
                        .font(.system(size: height * 0.26, weight: .regular, design: .rounded))
                        .foregroundStyle(Color(white: 0.45))
                    Spacer()
                    HStack(spacing: width * 0.012) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(white: 0.55))
                                .overlay(RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                                .frame(width: width * 0.035, height: height * 0.30)
                        }
                    }
                    Circle() // power LED
                        .fill(Color.green)
                        .frame(width: height * 0.14, height: height * 0.14)
                        .shadow(color: .green, radius: height * 0.08)
                        .padding(.leading, width * 0.015)
                }
                .padding(.horizontal, width * 0.05)
            }
        }
    }
}

/// Rotary pot dial: 270° sweep, dark plastic body with a pointer line.
/// Drag vertically or scroll to adjust; double-click snaps to center.
///
/// During a drag only local @State (the pointer) and the `live` closure
/// update — nothing observable publishes, so the video render loop is
/// untouched. `commit` fires once on release to persist.
struct KnobDial: View {
    let initial: Double
    let live: (Double) -> Void
    let commit: (Double) -> Void

    @State private var value: Double = 0.5
    @State private var dragStartValue: Double?

    // 270° sweep centered on straight-up: from -225° to +45° in
    // standard math angles, i.e. 7 o'clock around to 5 o'clock.
    private var angle: Angle { .degrees(-135 + value.clamped01 * 270) }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Body with a slight top-light gradient and rim.
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(white: 0.32), Color(white: 0.14)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: s * 0.05, y: s * 0.04)
                // Pointer line from center to edge.
                Capsule()
                    .fill(Color(white: 0.85))
                    .frame(width: s * 0.07, height: s * 0.34)
                    .offset(y: -s * 0.26)
                    .rotationEffect(angle)
            }
        }
        .onAppear { value = initial }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragStartValue == nil { dragStartValue = value }
                    // Full sweep over ~120 px of vertical travel.
                    let delta = -drag.translation.height / 120
                    value = ((dragStartValue ?? value) + delta).clamped01
                    live(value)
                }
                .onEnded { _ in
                    dragStartValue = nil
                    commit(value)
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                value = 0.5
                live(0.5)
                commit(0.5)
            }
        )
        .help("Drag up or down to adjust; double-click to center")
    }
}

private extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
