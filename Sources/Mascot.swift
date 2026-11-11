import SwiftUI
import notify

// The Claude Code critter. It lives behind the notch and peeks out at random.
// When Claude Code finishes a reply (a Stop hook posts `local.notchify.claude.done`)
// it walks out, shows off and then waits there until it is clicked or the next
// prompt is sent (a UserPromptSubmit hook posts `local.notchify.claude.prompt`).

enum MascotSide: String {
    case left, right
}

enum MascotAct: String {
    case wave, jump, crouch, blink
    /// A single lazy blink while it waits; not one of the tricks.
    case glance

    static let tricks: [MascotAct] = [.wave, .jump, .crouch, .blink]

    var duration: Double {
        switch self {
        case .wave: return 1.8
        case .jump: return 1.4
        case .crouch: return 1.4
        case .blink: return 1.3
        case .glance: return 0.4
        }
    }
}

enum MascotKind {
    /// `depth` is how far it leans out (0…1 of its width), `hold` how long it stays.
    case peek(depth: Double, hold: Double)
    /// Walks out, does a trick and stays until dismissed.
    case visit
}

struct MascotPerformance {
    var kind: MascotKind
    var side: MascotSide
    var start: Date
    // Times below are seconds since `start`.
    var act: MascotAct?
    var actStart = 0.0
    var leaveAt: Double?
    /// Standing still outside: nothing moves, so the timeline can sleep.
    var resting = false
}

struct MascotPose {
    var emerge = 0.0      // 0 = hidden behind the widget, 1 = fully out
    var lift = 0.0        // points above the floor
    var crouch = 0.0      // 0…1, body lowered onto the legs
    var eye = 1.0         // 1 = open, 0 = closed
    var arm = 0.0         // outer arm raise, in grid cells
    var stride = 0.0      // 0…1, how much the legs are stepping
    var stridePhase = 0.0
}

// MARK: - Choreography

enum MascotScript {
    static let peekIn = 0.34
    static let peekOut = 0.26
    static let walkIn = 0.5
    static let settle = 0.18
    static let walkOut = 0.42

    static func peekDuration(hold: Double) -> Double { peekIn + hold + peekOut }

    static func pose(_ performance: MascotPerformance, at t: Double) -> MascotPose {
        var pose = MascotPose()
        switch performance.kind {
        case .peek(let depth, let hold):
            let leaving = easeIn(progress(t, peekIn + hold, peekIn + hold + peekOut))
            pose.emerge = depth * easeOutBack(progress(t, 0, peekIn)) * (1 - leaving)
            pose.eye = blink(t, at: peekIn + hold * 0.55)

        case .visit:
            if performance.resting {
                pose.emerge = 1
                return pose
            }
            let leaveAt = performance.leaveAt
            let leaving = leaveAt.map { easeIn(progress(t, $0, $0 + walkOut)) } ?? 0
            pose.emerge = easeOut(progress(t, 0, walkIn)) * (1 - leaving)

            if t < walkIn || (leaveAt.map { t > $0 } ?? false) {
                pose.stride = 1
                pose.stridePhase = t * 2 * .pi * 5
                pose.lift = abs(sin(pose.stridePhase)) * 1.2
            } else if let act = performance.act {
                let u = t - performance.actStart
                if u >= 0, u <= act.duration { apply(act, at: u, to: &pose) }
            }
        }
        return pose
    }

    private static func apply(_ act: MascotAct, at u: Double, to pose: inout MascotPose) {
        switch act {
        case .wave:
            let raised = easeOut(progress(u, 0, 0.18)) * (1 - easeIn(progress(u, 1.6, 1.8)))
            pose.arm = raised * (2.3 + 0.9 * sin(u * 2 * .pi * 3.2))
            pose.eye = blink(u, at: 1.0)

        case .jump:
            let hop = 0.7
            let v = u.truncatingRemainder(dividingBy: hop)
            if v < 0.15 {                       // wind up
                pose.crouch = easeOut(v / 0.15)
            } else if v < 0.52 {                // airborne
                let p = (v - 0.15) / 0.37
                pose.lift = 4 * p * (1 - p) * 7
                pose.arm = sin(p * .pi) * 1.6
            } else {                            // land
                let p = (v - 0.52) / (hop - 0.52)
                pose.crouch = sin(p * .pi) * 0.7
            }

        case .crouch:
            let squat = 0.7
            let v = u.truncatingRemainder(dividingBy: squat)
            pose.crouch = easeOut(progress(v, 0, 0.2)) * (1 - easeOut(progress(v, 0.4, 0.62)))

        case .blink:
            pose.eye = min(blink(u, at: 0.25), blink(u, at: 0.62), blink(u, at: 0.99))

        case .glance:
            pose.eye = blink(u, at: 0.2)
        }
    }

    private static func progress(_ t: Double, _ from: Double, _ to: Double) -> Double {
        min(max((t - from) / (to - from), 0), 1)
    }

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private static func easeIn(_ x: Double) -> Double { x * x * x }

    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158
        return 1 + (c1 + 1) * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// 1 everywhere except a short dip to 0 around `center`.
    private static func blink(_ t: Double, at center: Double) -> Double {
        min(abs(t - center) / 0.09, 1)
    }
}

// MARK: - Model

final class MascotModel: ObservableObject {
    static let doneNotification = "local.notchify.claude.done"
    static let promptNotification = "local.notchify.claude.prompt"
    static let peekNotification = "local.notchify.claude.peek"
    private static let enabledKey = "mascotEnabled"

    @Published private(set) var performance: MascotPerformance?
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled {
                scheduleNextPeek(in: 5...15)
            } else {
                peekWork?.cancel()
                stepWork?.cancel()
                performance = nil
            }
        }
    }

    /// The next step of whatever it is doing now (rest, fidget, go home).
    private var stepWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var lastAct: MascotAct?
    private var tokens: [Int32] = []

    // Debug: pin the trick and the side instead of rolling the dice.
    private let forcedAct = ProcessInfo.processInfo.environment["NOTCHIFY_MASCOT_ACT"].flatMap(MascotAct.init)
    private let forcedSide = ProcessInfo.processInfo.environment["NOTCHIFY_MASCOT_SIDE"].flatMap(MascotSide.init)

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        listen(Self.doneNotification) { [weak self] in self?.celebrate() }
        listen(Self.promptNotification) { [weak self] in self?.dismiss() }
        listen(Self.peekNotification) { [weak self] in self?.peek() }
        if enabled { scheduleNextPeek(in: 20...60) }
    }

    deinit { tokens.forEach { notify_cancel($0) } }

    /// Which side it is standing on while it waits to be dismissed (nil = not out).
    var waitingSide: MascotSide? {
        guard let performance, case .visit = performance.kind, performance.leaveAt == nil else { return nil }
        return performance.side
    }

    var debugDescription: String {
        guard let p = performance else { return "idle enabled=\(enabled)" }
        let t = String(format: "%.2f", Date().timeIntervalSince(p.start))
        let state = p.leaveAt != nil ? "leaving" : (p.resting ? "resting" : "act=\(p.act?.rawValue ?? "-")")
        return "\(p.kind) side=\(p.side.rawValue) \(state) t=\(t)"
    }

    // MARK: Events

    /// Claude Code finished a reply: walk out, show off and wait.
    func celebrate() {
        guard enabled else { return }
        let act = forcedAct ?? MascotAct.tricks.filter { $0 != lastAct }.randomElement() ?? .wave

        if let p = performance, case .visit = p.kind, p.leaveAt == nil {
            // Already standing outside and another reply landed: one more trick.
            let t = Date().timeIntervalSince(p.start)
            let busy = p.act.map { t < p.actStart + $0.duration } ?? false
            if !busy {
                lastAct = act
                play(act)
            }
            return
        }

        lastAct = act
        // If it is peeking right now, come out on the same side.
        let side = forcedSide ?? performance?.side ?? (Bool.random() ? .left : .right)
        let actStart = MascotScript.walkIn + MascotScript.settle
        performance = MascotPerformance(kind: .visit, side: side, start: Date(), act: act, actStart: actStart)
        step(after: actStart + act.duration) { $0.rest() }
    }

    /// The user clicked it or sent the next prompt: walk back behind the widget.
    func dismiss() {
        guard var p = performance, case .visit = p.kind, p.leaveAt == nil else { return }
        let t = Date().timeIntervalSince(p.start)
        let leaveAt = max(t, MascotScript.walkIn) // let it finish walking out first
        p.resting = false
        p.act = nil
        p.leaveAt = leaveAt
        performance = p
        step(after: leaveAt - t + MascotScript.walkOut) { $0.finish() }
    }

    func peek() {
        guard enabled, performance == nil else { return }
        let hold = Double.random(in: 1.1...2.4)
        performance = MascotPerformance(
            kind: .peek(depth: .random(in: 0.42...0.62), hold: hold),
            side: forcedSide ?? (Bool.random() ? .left : .right), start: Date())
        step(after: MascotScript.peekDuration(hold: hold)) { $0.finish() }
    }

    // MARK: Steps

    private func play(_ act: MascotAct) {
        guard var p = performance else { return }
        p.resting = false
        p.act = act
        p.actStart = Date().timeIntervalSince(p.start)
        performance = p
        step(after: act.duration) { $0.rest() }
    }

    /// Stand still; every few seconds blink, once in a while repeat a trick.
    private func rest() {
        guard var p = performance, case .visit = p.kind, p.leaveAt == nil else { return }
        p.resting = true
        p.act = nil
        performance = p
        step(after: .random(in: 3...7)) { model in
            let trick = Double.random(in: 0..<1) < 0.1
            model.play(trick ? (MascotAct.tricks.randomElement() ?? .wave) : .glance)
        }
    }

    private func finish() {
        performance = nil
        scheduleNextPeek(in: 45...150)
    }

    private func step(after delay: Double, _ action: @escaping (MascotModel) -> Void) {
        stepWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            action(self)
        }
        stepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05, execute: work)
    }

    private func scheduleNextPeek(in range: ClosedRange<Double>) {
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.performance == nil {
                self.peek()
            } else {
                self.scheduleNextPeek(in: range)
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: range), execute: work)
    }

    private func listen(_ name: String, handler: @escaping () -> Void) {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.main) { _ in handler() }
        if status == 0 { tokens.append(token) } // NOTIFY_STATUS_OK
    }
}

// MARK: - Views

/// Places the critter at the side edge of the widget body; the caller masks out
/// the body so whatever has not emerged yet stays hidden behind it.
struct MascotLayer: View {
    @ObservedObject var mascot: MascotModel
    /// Distance from the notch centre to the body's side edge.
    var edge: CGFloat
    /// Where its feet stand, measured from the top of the screen.
    var floor: CGFloat

    var body: some View {
        let side = mascot.performance?.side ?? .right
        let direction: CGFloat = side == .left ? -1 : 1
        let size = MascotSprite.size
        let asleep = mascot.performance?.resting ?? true

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: asleep)) { context in
            let pose = mascot.performance.map {
                MascotScript.pose($0, at: context.date.timeIntervalSince($0.start))
            } ?? MascotPose()

            MascotSprite(pose: pose)
                .contentShape(Rectangle())
                .onTapGesture { mascot.dismiss() }
                .scaleEffect(x: direction, y: 1)
                .offset(x: direction * (-size.width / 2 + pose.emerge * (size.width + Metrics.mascotGap)),
                        y: floor - size.height - pose.lift)
        }
        // Kept outside the timeline so a change of widget width animates with the widget.
        .offset(x: direction * edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(mascot.performance == nil ? 0 : 1)
    }
}

/// Pixel-art critter on an 18×10 grid, drawn facing its right (outer) side.
struct MascotSprite: View {
    static let cell: CGFloat = 2
    static let size = CGSize(width: 18 * cell, height: 10 * cell)

    private static let bodyColor = Color(red: 0.851, green: 0.467, blue: 0.341)
    private static let eyeColor = Color(red: 0.13, green: 0.09, blue: 0.08)
    /// Dark rim so it reads on a light menu bar as well as on a dark one.
    private static let outlineColor = Color(red: 0.16, green: 0.08, blue: 0.05)
    private static let outline: CGFloat = 1.5

    var pose: MascotPose

    var body: some View {
        Canvas { canvas, _ in
            let cell = Self.cell
            canvas.translateBy(x: Self.outline, y: Self.outline)
            func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
                Path(CGRect(x: x * cell, y: y * cell, width: w * cell, height: max(h, 0) * cell))
            }
            let drop = pose.crouch * 1.5 // body sinks onto the legs

            var shape = Path()
            for (index, column) in [4.0, 6.0, 11.0, 13.0].enumerated() {
                let swing = sin(pose.stridePhase) * (index % 2 == 0 ? 1 : -1)
                let raised = max(swing, 0) * pose.stride
                shape.addPath(block(column, 8 + drop, 1, 2 - drop - raised))
            }
            shape.addPath(block(3, drop, 12, 8))                    // body
            shape.addPath(block(1, 4 + drop, 2, 2))                 // inner arm
            shape.addPath(block(15, 4 + drop - pose.arm, 2, 2))     // outer arm
            // Stroke every block, then fill on top: only the outer half of the stroke survives.
            canvas.stroke(shape, with: .color(Self.outlineColor),
                          style: StrokeStyle(lineWidth: 2 * Self.outline, lineJoin: .miter))
            canvas.fill(shape, with: .color(Self.bodyColor))

            let eyeHeight = max(2 * pose.eye, 0.35)
            let eyeTop = 2 + drop + (2 - eyeHeight) * 0.6
            var eyes = block(5, eyeTop, 1, eyeHeight)
            eyes.addPath(block(12, eyeTop, 1, eyeHeight))
            canvas.fill(eyes, with: .color(Self.eyeColor))
        }
        // The canvas is larger than the sprite by the rim; layout still sees the bare sprite.
        .frame(width: Self.size.width + 2 * Self.outline, height: Self.size.height + 2 * Self.outline)
        .padding(-Self.outline)
    }
}
