import AppKit
import Combine
import SwiftUI

/// Geometry shared by the SwiftUI view and the hover hit-testing.
enum Metrics {
    static let windowSize = CGSize(width: 640, height: 340)
    static let expandedBodyWidth: CGFloat = 400
    static let playerContentHeight: CGFloat = 204
    static let messageContentHeight: CGFloat = 62
    static let collapsedFlare: CGFloat = 6
    static let expandedFlare: CGFloat = 12

    /// Both directions are 38% quicker than the original 0.42 s spring.
    static let openSpring = Animation.spring(response: 0.26, dampingFraction: 0.8)
    static let closeSpring = Animation.spring(response: 0.26, dampingFraction: 0.88)
    /// How long the cursor must rest on the notch before the panel opens.
    static let openDelay = 0.043
    /// How long the cursor may stay outside the panel before it closes.
    static let closeDelay = 0.174

    static func wingWidth(notchHeight: CGFloat) -> CGFloat { notchHeight + 8 }

    /// Space between the widget and the mascot standing next to it.
    static let mascotGap: CGFloat = 4
    /// How far above the notch's bottom edge the mascot's feet are.
    static let mascotFloorInset: CGFloat = 4
}

final class NotchUIState: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 190, height: 32)
    /// The device list replaces the player inside the open panel.
    @Published var showingDevices = false
    /// The wings switch is remembered separately for music on this Mac (on by default)
    /// and for music on another device (off by default). The panel opens on hover either way.
    @Published var wingsHidden = UserDefaults.standard.bool(forKey: "wingsHidden") {
        didSet { UserDefaults.standard.set(wingsHidden, forKey: "wingsHidden") }
    }
    @Published var wingsShownElsewhere = UserDefaults.standard.bool(forKey: "wingsShownElsewhere") {
        didSet { UserDefaults.standard.set(wingsShownElsewhere, forKey: "wingsShownElsewhere") }
    }

    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { if oldValue != launchAtLogin { LoginItem.setEnabled(launchAtLogin) } }
    }

    /// The switch as it stands for the place the music plays right now.
    func wingsEnabled(_ model: SpotifyModel) -> Bool {
        model.playingElsewhere ? wingsShownElsewhere : !wingsHidden
    }

    func setWingsEnabled(_ enabled: Bool, _ model: SpotifyModel) {
        if model.playingElsewhere { wingsShownElsewhere = enabled } else { wingsHidden = !enabled }
    }

    func showsWings(_ model: SpotifyModel) -> Bool {
        model.track != nil && !model.permissionDenied && model.isPlaying && wingsEnabled(model)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchController {
    private let model = SpotifyModel()
    private let ui = NotchUIState()
    private let mascot = MascotModel()
    private let connect = SpotifyConnect()
    private let panel: NotchPanel
    private var screen: NSScreen?

    private var fastTimer: Timer?
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private let forceExpanded = ProcessInfo.processInfo.environment["NOTCHIFY_FORCE_EXPANDED"] == "1"

    init() {
        panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: Metrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        let host = FirstMouseHostingView(
            rootView: NotchRootView(model: model, ui: ui, mascot: mascot, connect: connect))
        host.sizingOptions = []
        panel.contentView = host

        connect.onPlaybackMoved = { [weak self] in self?.model.refresh() }
        // The device list knows at once when the music moved to a TV, phone or speaker.
        deviceWatch = connect.$devices.sink { [weak self] devices in
            let active = devices.first { $0.isActive }
            self?.model.remoteDeviceActive = active.map { $0.type.lowercased() != "computer" } ?? false
        }
        model.onLocationHint = { [weak self] in self?.connect.reloadIfStale(after: 2) }
        connect.reload()

        layout()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.layout() }

        // Mouse tracking: a global monitor wakes us up, a slow timer is the safety net,
        // and a fast timer runs only while the cursor is on the notch.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.evaluateMouse()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.evaluateMouse()
            return event
        }
        let slow = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.evaluateMouse() }
        slow.tolerance = 0.1
        RunLoop.main.add(slow, forMode: .common)

        if forceExpanded {
            setExpanded(true)
            // Debug: NOTCHIFY_SHOW_DEVICES=1 opens the device list instead of the player.
            ui.showingDevices = ProcessInfo.processInfo.environment["NOTCHIFY_SHOW_DEVICES"] == "1"
        }

        // Debug: NOTCHIFY_SNAPSHOT=/path/file.png dumps the panel and the model state once.
        // `kill -USR1 <pid>` takes another one (file.png → file-1.png, file-2.png, …).
        if let path = ProcessInfo.processInfo.environment["NOTCHIFY_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.writeSnapshot(to: path) }

            signal(SIGUSR1, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.snapshotIndex += 1
                let numbered = path.replacingOccurrences(of: ".png", with: "-\(self.snapshotIndex).png")
                self.writeSnapshot(to: numbered)
            }
            source.resume()
            snapshotSignal = source

            // `kill -USR2 <pid>` opens the panel as if hovered; it closes itself as usual.
            signal(SIGUSR2, SIG_IGN)
            let expand = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
            expand.setEventHandler { [weak self] in self?.setExpanded(true) }
            expand.resume()
            expandSignal = expand
        }
    }

    private var deviceWatch: AnyCancellable?
    private var snapshotIndex = 0
    private var snapshotSignal: DispatchSourceSignal?
    private var expandSignal: DispatchSourceSignal?

    private func writeSnapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))

        let state = """
        running=\(model.isRunning) playing=\(model.isPlaying) denied=\(model.permissionDenied)
        track=\(model.track?.name ?? "nil") — \(model.track?.artist ?? "")
        duration=\(model.track?.duration ?? 0) position=\(model.currentPosition())
        volume=\(model.volume) shuffle=\(model.shuffling) repeat=\(model.repeating)
        artwork=\(model.artwork != nil) expanded=\(ui.expanded) notch=\(ui.notchSize)
        panel=\(panel.frame) visible=\(panel.isVisible) screen=\(screen?.frame ?? .zero)
        mouse=\(NSEvent.mouseLocation) zone=\(screen.map { hoverZone(on: $0) } ?? .zero) ignoresMouse=\(panel.ignoresMouseEvents)
        mascot=\(mascot.debugDescription)
        elsewhere=\(model.playingElsewhere) remoteDevice=\(model.remoteDeviceActive) wings=\(ui.showsWings(model))
        wingsHidden=\(ui.wingsHidden) wingsShownElsewhere=\(ui.wingsShownElsewhere)
        connect=\(connect.phase) devices=\(connect.devices.map { "\($0.name)[\($0.type)\($0.isActive ? ",active" : "")]" })
        """
        try? state.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }

    // MARK: - Layout

    private func layout() {
        guard let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            screen = nil
            panel.orderOut(nil)
            return
        }
        screen = notched

        let frame = notched.frame
        let left = notched.auxiliaryTopLeftArea?.width ?? 0
        let right = notched.auxiliaryTopRightArea?.width ?? 0
        let notchWidth = (left > 0 && right > 0) ? frame.width - left - right : 190
        ui.notchSize = CGSize(width: notchWidth, height: notched.safeAreaInsets.top)

        let size = Metrics.windowSize
        panel.setFrame(
            CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                   width: size.width, height: size.height),
            display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - Hover

    private var hasTrack: Bool { model.track != nil && !model.permissionDenied }

    private func hoverZone(on screen: NSScreen) -> CGRect {
        let notch = ui.notchSize
        var width = notch.width
        var height = notch.height
        if ui.expanded {
            width = Metrics.expandedBodyWidth + 2 * Metrics.expandedFlare + 16
            height = notch.height
                + (hasTrack ? Metrics.playerContentHeight : Metrics.messageContentHeight) + 10
        } else if ui.showsWings(model) {
            width += 2 * (Metrics.wingWidth(notchHeight: notch.height) + Metrics.collapsedFlare)
        }
        // Reach a little past the top edge so the cursor pinned to the edge still counts.
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                      width: width, height: height + 12)
    }

    /// Screen rect of the mascot while it stands outside waiting for a click.
    private func mascotRect(on screen: NSScreen) -> CGRect? {
        guard let side = mascot.waitingSide else { return nil }
        let notch = ui.notchSize
        var half = notch.width / 2
        if ui.expanded {
            half = Metrics.expandedBodyWidth / 2
        } else if ui.showsWings(model) {
            half += Metrics.wingWidth(notchHeight: notch.height)
        }
        let size = MascotSprite.size
        let inner = half + Metrics.mascotGap
        let x = side == .right ? screen.frame.midX + inner : screen.frame.midX - inner - size.width
        let feet = screen.frame.maxY - (notch.height - Metrics.mascotFloorInset)
        return CGRect(x: x, y: feet, width: size.width, height: size.height).insetBy(dx: -3, dy: -3)
    }

    private func evaluateMouse() {
        guard let screen, !forceExpanded else { return }
        let mouse = NSEvent.mouseLocation
        let overMascot = mascotRect(on: screen)?.contains(mouse) ?? false
        // Pointing at the mascot must not pop the player open; it only makes it clickable.
        let inside = hoverZone(on: screen).contains(mouse) && (ui.expanded || !overMascot)
        let pressed = NSEvent.pressedMouseButtons != 0
        // A slider drag may leave the panel; keep it open and interactive until release.
        let engaged = inside || (ui.expanded && pressed)

        panel.ignoresMouseEvents = !(engaged || overMascot)

        if engaged {
            collapseWork?.cancel()
            collapseWork = nil
            // Ignore drags passing through (moving a window to the top edge, etc.).
            if !ui.expanded && expandWork == nil && !pressed {
                let work = DispatchWorkItem { [weak self] in
                    self?.expandWork = nil
                    self?.setExpanded(true)
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.openDelay, execute: work)
            }
            startFastTimer()
        } else {
            expandWork?.cancel()
            expandWork = nil
            if ui.expanded {
                if collapseWork == nil {
                    let work = DispatchWorkItem { [weak self] in
                        self?.collapseWork = nil
                        self?.setExpanded(false)
                    }
                    collapseWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.closeDelay, execute: work)
                }
            } else if overMascot {
                startFastTimer() // notice quickly when the cursor leaves it
            } else {
                stopFastTimer()
            }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard ui.expanded != expanded else { return }
        withAnimation(expanded ? Metrics.openSpring : Metrics.closeSpring) {
            ui.expanded = expanded
            if !expanded { ui.showingDevices = false }
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        if expanded {
            // Volume, shuffle and repeat changes made elsewhere don't post notifications.
            model.refresh()
            connect.reloadIfStale()
            let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in self?.model.refresh() }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
    }

    private func startFastTimer() {
        guard fastTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.evaluateMouse() }
        RunLoop.main.add(timer, forMode: .common)
        fastTimer = timer
    }

    private func stopFastTimer() {
        fastTimer?.invalidate()
        fastTimer = nil
    }
}
