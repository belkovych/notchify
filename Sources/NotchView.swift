import SwiftUI

// MARK: - Shape

/// The notch silhouette: concave "ears" at the top that blend into the screen edge,
/// rounded corners at the bottom. The body is inset by `flare` on each side.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set { flare = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.width / 4)
        let r = min(bottomRadius, rect.height / 2, (rect.width - 2 * f) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f),
                       control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX + f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var model: SpotifyModel
    @ObservedObject var ui: NotchUIState
    @ObservedObject var mascot: MascotModel
    @ObservedObject var connect: SpotifyConnect
    @Namespace private var ns

    private enum Mode { case hidden, wings, player, devices, message }

    private var mode: Mode {
        let hasTrack = model.track != nil && !model.permissionDenied
        if ui.expanded {
            guard hasTrack else { return .message }
            return ui.showingDevices ? .devices : .player
        }
        return ui.showsWings(model) ? .wings : .hidden
    }

    private var wing: CGFloat { Metrics.wingWidth(notchHeight: ui.notchSize.height) }

    private var bodySize: CGSize {
        let notch = ui.notchSize
        switch mode {
        case .hidden: return notch
        case .wings: return CGSize(width: notch.width + 2 * wing, height: notch.height)
        case .player, .devices:
            return CGSize(width: Metrics.expandedBodyWidth, height: notch.height + Metrics.playerContentHeight)
        case .message:
            return CGSize(width: Metrics.expandedBodyWidth, height: notch.height + Metrics.messageContentHeight)
        }
    }

    var body: some View {
        let expanded = mode == .player || mode == .devices || mode == .message
        let flare = expanded ? Metrics.expandedFlare : Metrics.collapsedFlare
        let shape = NotchShape(flare: flare, bottomRadius: expanded ? 28 : 10)
        let size = bodySize
        let notch = ui.notchSize

        ZStack(alignment: .top) {
            // The critter stands in the menu bar strip, behind the widget: the mask cuts
            // the widget's silhouette out of it, so it also hides behind the bare notch.
            MascotLayer(mascot: mascot, edge: size.width / 2, floor: notch.height - Metrics.mascotFloorInset)
                .mask {
                    Rectangle()
                        .overlay(alignment: .top) {
                            shape
                                .frame(width: size.width + 2 * flare, height: size.height)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }

            notchBody(shape: shape, size: size, flare: flare, expanded: expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(expanded ? Metrics.openSpring : Metrics.closeSpring, value: mode)
    }

    private func notchBody(shape: NotchShape, size: CGSize, flare: CGFloat, expanded: Bool) -> some View {
        let notch = ui.notchSize

        return ZStack(alignment: .top) {
            shape.fill(.black)

            if mode == .player || mode == .devices {
                FlowingGradient(palette: model.palette)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: notch.height / size.height * 0.8),
                                .init(color: .white, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom))
                    .opacity(mode == .devices ? 0.32 : 0.5)
                    .transition(.opacity)
            }

            switch mode {
            case .hidden:
                EmptyView()
            case .wings:
                WingsView(model: model, ns: ns, wing: wing, notch: notch)
                    .transition(.opacity)
            case .player:
                PlayerView(model: model, ui: ui, connect: connect, ns: ns)
                    .frame(width: Metrics.expandedBodyWidth, height: Metrics.playerContentHeight)
                    .padding(.top, notch.height)
                    .transition(.opacity)
            case .devices:
                DevicesView(model: model, connect: connect) { ui.showingDevices = false }
                    .frame(width: Metrics.expandedBodyWidth, height: Metrics.playerContentHeight)
                    .padding(.top, notch.height)
                    .transition(.opacity)
            case .message:
                MessageView(model: model)
                    .frame(width: Metrics.expandedBodyWidth, height: Metrics.messageContentHeight)
                    .padding(.top, notch.height)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + 2 * flare, height: size.height)
        .clipShape(shape)
        .contentShape(shape)
        .contextMenu {
            Button("Відкрити Spotify") { model.openSpotify() }
            Toggle("Вушка біля вирізу", isOn: Binding(
                get: { ui.wingsEnabled(model) }, set: { ui.setWingsEnabled($0, model) }))
            Toggle("Claude визирає", isOn: $mascot.enabled)
            Toggle("Запускати при вході", isOn: $ui.launchAtLogin)
            if connect.phase == .ready {
                Button("Відʼєднати Spotify Connect") { connect.signOut() }
            }
            Divider()
            Button("Вийти з Notchify") { NSApp.terminate(nil) }
        }
        .shadow(color: model.palette.colors[0].opacity(mode == .player || mode == .devices ? 0.28 : 0),
                radius: 24, y: 8)
        .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 16, y: 10)
        .opacity(mode == .hidden ? 0 : 1)
    }
}

// MARK: - Collapsed wings

private struct WingsView: View {
    @ObservedObject var model: SpotifyModel
    let ns: Namespace.ID
    let wing: CGFloat
    let notch: CGSize

    var body: some View {
        let cover = notch.height - 12
        HStack(spacing: 0) {
            CoverView(image: model.artwork, radius: 5)
                .matchedGeometryEffect(id: "cover", in: ns)
                .frame(width: cover, height: cover)
                .frame(width: wing)
            Spacer(minLength: 0)
            EqualizerBars(playing: model.isPlaying, color: model.palette.accent)
                .frame(width: 16, height: 13)
                .frame(width: wing)
        }
        .frame(width: notch.width + 2 * wing, height: notch.height)
    }
}

// MARK: - Expanded player

private struct PlayerView: View {
    @ObservedObject var model: SpotifyModel
    @ObservedObject var ui: NotchUIState
    @ObservedObject var connect: SpotifyConnect
    let ns: Namespace.ID

    /// Where the sound comes out: this Mac, or the active Spotify Connect device.
    private var deviceSymbol: String {
        guard model.playingElsewhere else { return "laptopcomputer" }
        return connect.activeDevice?.symbol ?? "hifispeaker.fill"
    }

    var body: some View {
        let accent = model.palette.accent
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Button { model.openSpotify() } label: {
                    CoverView(image: model.artwork, radius: 12)
                        .matchedGeometryEffect(id: "cover", in: ns)
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.track?.name ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(model.track?.artist ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                EqualizerBars(playing: model.isPlaying, color: accent)
                    .frame(width: 18, height: 16)
            }

            Spacer(minLength: 0)
            ProgressRow(model: model, tint: accent)
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                ToggleIcon(symbol: "shuffle", active: model.shuffling, tint: accent) { model.toggleShuffle() }
                Spacer()
                HStack(spacing: 16) {
                    IconButton(symbol: "backward.fill", fontSize: 17, size: 36) { model.previous() }
                    IconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", fontSize: 24, size: 42) {
                        model.togglePlay()
                    }
                    IconButton(symbol: "forward.fill", fontSize: 17, size: 36) { model.next() }
                }
                Spacer()
                ToggleIcon(symbol: "repeat", active: model.repeating, tint: accent) { model.toggleRepeat() }
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                ToggleIcon(symbol: deviceSymbol, active: model.playingElsewhere, tint: accent) {
                    ui.showingDevices = true
                }
                .help("Де грає музика")

                HStack(spacing: 9) {
                    Image(systemName: "speaker.fill").opacity(0.55)
                    SliderBar(
                        fraction: model.volume / 100, tint: .white.opacity(0.85),
                        onChange: { model.setVolume($0 * 100, final: false) },
                        onEnd: { model.setVolume($0 * 100, final: true) })
                    Image(systemName: "speaker.wave.3.fill").opacity(0.55)
                }
                .font(.system(size: 10, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)

                let wings = ui.wingsEnabled(model)
                ToggleIcon(active: wings, tint: accent, action: { ui.setWingsEnabled(!wings, model) },
                           glyph: WingsGlyph(on: wings))
                    .help(wings ? "Сховати вушка біля вирізу" : "Показувати вушка біля вирізу")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

private struct ProgressRow: View {
    @ObservedObject var model: SpotifyModel
    var tint: Color
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = max(model.track?.duration ?? 0, 0.1)
            let position = dragFraction.map { $0 * duration } ?? model.currentPosition(at: context.date)
            HStack(spacing: 8) {
                Text(Self.format(position))
                    .frame(width: 36, alignment: .leading)
                SliderBar(
                    fraction: position / duration, tint: tint,
                    onChange: { dragFraction = $0 },
                    onEnd: { fraction in
                        model.seek(to: fraction * duration)
                        dragFraction = nil
                    })
                Text("-" + Self.format(duration - position))
                    .frame(width: 36, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Message (Spotify closed, nothing playing, no permission)

private struct MessageView: View {
    @ObservedObject var model: SpotifyModel

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.12, green: 0.84, blue: 0.38)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    private var text: String {
        if model.permissionDenied { return "Немає дозволу керувати Spotify (Privacy → Automation)" }
        return model.isRunning ? "Зараз нічого не грає" : "Spotify не запущено"
    }

    private var buttonTitle: String { model.permissionDenied ? "Налаштування" : "Відкрити Spotify" }

    private func action() {
        if model.permissionDenied,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        } else {
            model.openSpotify()
        }
    }
}

// MARK: - Pieces

private struct CoverView: View {
    let image: NSImage?
    let radius: CGFloat

    var body: some View {
        ZStack {
            Color(white: 0.16)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Bars that dance while music plays and settle flat when paused.
struct EqualizerBars: View {
    var playing: Bool
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = 4
                let gap: CGFloat = 2
                let barWidth = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                for i in 0..<count {
                    let fi = Double(i)
                    let wave = sin(t * (5.1 + fi * 1.3) + fi * 1.7) * 0.6 + sin(t * (2.3 + fi * 0.7) + fi) * 0.4
                    let level = playing ? 0.28 + 0.72 * abs(wave) : 0.22
                    let height = max(barWidth, size.height * level)
                    let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - height) / 2,
                                      width: barWidth, height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
        }
    }
}

/// Slim bar that thickens under the cursor; drag anywhere on it to scrub.
private struct SliderBar: View {
    var fraction: Double
    var tint: Color
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let active = hovering || dragging
            let thickness: CGFloat = active ? 7 : 4
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(tint)
                    .frame(width: max(thickness, geo.size.width * clamped))
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        onChange(min(max(value.location.x / geo.size.width, 0), 1))
                    }
                    .onEnded { value in
                        dragging = false
                        onEnd(min(max(value.location.x / geo.size.width, 0), 1))
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 16)
    }
}

private struct IconButton: View {
    var symbol: String
    var fontSize: CGFloat
    var size: CGFloat
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct ToggleIcon<Glyph: View>: View {
    var active: Bool
    var tint: Color
    var action: () -> Void
    var glyph: Glyph

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                glyph
                    .font(.system(size: 13, weight: .bold))
                    .frame(height: 15)
                Circle()
                    .frame(width: 3.5, height: 3.5)
                    .opacity(active ? 1 : 0)
            }
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(active ? tint : .white)
            .opacity(active ? 1 : (hovering ? 0.85 : 0.5))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: active)
    }
}

private extension ToggleIcon where Glyph == Image {
    init(symbol: String, active: Bool, tint: Color, action: @escaping () -> Void) {
        self.init(active: active, tint: tint, action: action, glyph: Image(systemName: symbol))
    }
}

/// The widget in miniature: the notch with its two wings (cover on the left, bars on the right).
/// The wings fade out when they are switched off.
private struct WingsGlyph: View {
    var on: Bool

    var body: some View {
        Canvas { canvas, size in
            let midY = size.height / 2
            let wings = on ? 1.0 : 0.28

            let notch = CGRect(x: size.width / 2 - 4.5, y: 0, width: 9, height: size.height)
            canvas.fill(Path(roundedRect: notch, cornerRadius: 2.5), with: .style(.foreground.opacity(0.5)))

            let cover = CGRect(x: 0.5, y: midY - 2.75, width: 5.5, height: 5.5)
            canvas.fill(Path(roundedRect: cover, cornerRadius: 1.5), with: .style(.foreground.opacity(wings)))

            for (index, height) in [3.5, 7.0, 5.0].enumerated() {
                let bar = CGRect(x: size.width - 6.1 + CGFloat(index) * 2.2, y: midY - height / 2,
                                 width: 1.5, height: height)
                canvas.fill(Path(roundedRect: bar, cornerRadius: 0.75), with: .style(.foreground.opacity(wings)))
            }
        }
        .frame(width: 25, height: 11)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Living gradient

/// Cover colors on a 3×3 mesh whose points drift and whose colors breathe into each other.
private struct FlowingGradient: View {
    var palette: Palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors(t), smoothsColors: true)
        }
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double, _ amplitude: Double) -> Float {
            Float(sin(t * speed + phase) * amplitude)
        }
        return [
            SIMD2(0, 0), SIMD2(0.5 + wave(0.62, 0.0, 0.26), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + wave(0.51, 1.3, 0.26)),
            SIMD2(0.5 + wave(0.73, 2.1, 0.30), 0.5 + wave(0.57, 4.0, 0.30)),
            SIMD2(1, 0.5 + wave(0.46, 3.2, 0.26)),
            SIMD2(0, 1), SIMD2(0.5 + wave(0.66, 5.1, 0.26), 1), SIMD2(1, 1),
        ]
    }

    private func colors(_ t: Double) -> [Color] {
        let c = palette.colors
        // Which palette color sits on each mesh point, and which one it drifts toward.
        let layout = [0, 1, 2, 2, 3, 1, 1, 0, 3]
        return layout.enumerated().map { index, slot in
            let blend = 0.5 + 0.5 * sin(t * 0.45 + Double(index) * 0.9)
            return c[slot % c.count].mix(with: c[(slot + 1) % c.count], by: blend * 0.6)
        }
    }
}
