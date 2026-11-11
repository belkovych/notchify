import AppKit
import SwiftUI

struct Track: Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var artworkURL: String
    var duration: Double // seconds
}

/// Runs AppleScript off the main thread, one script at a time.
final class ScriptRunner {
    private let queue = DispatchQueue(label: "notchify.applescript")

    func run(_ source: String, completion: ((NSAppleEventDescriptor?, Int?) -> Void)? = nil) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let code = error?[NSAppleScript.errorNumber] as? Int
            guard let completion else { return }
            DispatchQueue.main.async { completion(error == nil ? result : nil, code) }
        }
    }
}

final class SpotifyModel: ObservableObject {
    static let bundleID = "com.spotify.client"

    @Published var isRunning = false
    @Published var track: Track?
    @Published var isPlaying = false {
        didSet { if oldValue != isPlaying { updateLocation() } }
    }
    /// Spotify says "playing", but the sound comes out of another device (Spotify Connect).
    @Published private(set) var playingElsewhere = false
    /// The Spotify Connect list says the active device is a TV, phone or speaker. Needed because
    /// Spotify keeps its audio output open for a while after the music moved away from this Mac.
    var remoteDeviceActive = false {
        didSet { if oldValue != remoteDeviceActive { publishLocation() } }
    }
    /// Something hinted that the music may have moved (playback event, sound started or stopped).
    var onLocationHint: (() -> Void)?
    /// Playing, but Spotify sends no sound to this Mac's output.
    private var silentHere = false {
        didSet { if oldValue != silentHere { publishLocation() } }
    }
    @Published var position: Double = 0
    @Published var positionDate = Date()
    @Published var volume: Double = 50
    @Published var shuffling = false
    @Published var repeating = false
    @Published var artwork: NSImage?
    @Published var palette: Palette = .fallback
    @Published var permissionDenied = false

    private let runner = ScriptRunner()
    private var artworkURLLoaded = ""
    private var lastVolumeSend = Date.distantPast

    private let audio = AudioOutputMonitor(bundlePrefix: SpotifyModel.bundleID)
    private var elsewhereWork: DispatchWorkItem?
    private var locationSeen = false

    init() {
        isRunning = Self.spotifyIsRunning()

        audio.onChange = { [weak self] in
            guard let self else { return }
            // Sound starting here outweighs an older device list; a fresh one is requested below.
            if self.audio.isOutputting { self.remoteDeviceActive = false }
            self.updateLocation()
            self.onLocationHint?()
        }
        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.audio.poll()
        }
        poll.tolerance = 1
        RunLoop.main.add(poll, forMode: .common)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        refresh()
    }

    static func spotifyIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Position right now, extrapolated from the last known sample.
    func currentPosition(at date: Date = Date()) -> Double {
        guard let track else { return 0 }
        let elapsed = isPlaying ? max(date.timeIntervalSince(positionDate), 0) : 0
        return min(max(position + elapsed, 0), track.duration)
    }

    // MARK: - Where the music plays

    /// Sound from Spotify on this Mac means "here", at once. Playing without sound means
    /// "elsewhere", but only after a moment: local playback needs a beat to start its output.
    /// While paused the last answer stands, so pausing on the TV doesn't flash the wings.
    private func publishLocation() {
        let elsewhere = silentHere || remoteDeviceActive
        if elsewhere != playingElsewhere { playingElsewhere = elsewhere }
    }

    private func updateLocation() {
        if audio.isOutputting {
            elsewhereWork?.cancel()
            elsewhereWork = nil
            locationSeen = true
            silentHere = false
        } else if isPlaying {
            guard !silentHere, elsewhereWork == nil else { return }
            // First look after launch: nothing to wait for, the music was already going.
            if !locationSeen {
                locationSeen = true
                silentHere = true
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.elsewhereWork = nil
                if self.isPlaying && !self.audio.isOutputting { self.silentHere = true }
            }
            elsewhereWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        } else {
            elsewhereWork?.cancel()
            elsewhereWork = nil
        }
    }

    // MARK: - Notifications

    @objc private func playbackChanged(_ note: Notification) {
        // Spotify posts "Stopped" while quitting; talking to it then would relaunch it.
        if (note.userInfo?["Player State"] as? String) == "Stopped" {
            isPlaying = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.isRunning = Self.spotifyIsRunning()
                if !self.isRunning { self.track = nil }
            }
            return
        }
        refresh()
        onLocationHint?()
    }

    @objc private func appsChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.bundleID else { return }
        let launched = note.name == NSWorkspace.didLaunchApplicationNotification
        isRunning = launched
        if launched {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
        } else {
            isPlaying = false
            track = nil
        }
    }

    // MARK: - State

    func refresh() {
        guard Self.spotifyIsRunning() else {
            isRunning = false
            isPlaying = false
            track = nil
            return
        }
        isRunning = true

        let script = """
        if application "Spotify" is running then
            try
                tell application "Spotify"
                    set ps to "stopped"
                    if player state is playing then
                        set ps to "playing"
                    else if player state is paused then
                        set ps to "paused"
                    end if
                    set t to current track
                    set art to ""
                    try
                        set art to artwork url of t
                    end try
                    return {ps, id of t, name of t, artist of t, album of t, art, duration of t, player position, sound volume, shuffling, repeating}
                end tell
            on error errMsg number errNum
                return {"error", errNum}
            end try
        else
            return {"notrunning"}
        end if
        """
        runner.run(script) { [weak self] result, code in
            self?.apply(result, errorCode: code)
        }
    }

    private func apply(_ result: NSAppleEventDescriptor?, errorCode: Int?) {
        if errorCode == -1743 { permissionDenied = true; return }
        guard let result, result.numberOfItems >= 1 else { return }
        let head = result.atIndex(1)?.stringValue ?? ""

        switch head {
        case "notrunning":
            isRunning = false
            isPlaying = false
            track = nil
        case "error":
            let num = Int(result.atIndex(2)?.int32Value ?? 0)
            if num == -1743 {
                permissionDenied = true
            } else {
                // No current track yet (fresh launch) or a transient failure.
                isPlaying = false
            }
        default:
            guard result.numberOfItems >= 11 else { return }
            permissionDenied = false
            func str(_ i: Int) -> String { result.atIndex(i)?.stringValue ?? "" }

            let newTrack = Track(
                id: str(2), name: str(3), artist: str(4), album: str(5), artworkURL: str(6),
                duration: Double(result.atIndex(7)?.int32Value ?? 0) / 1000.0)
            if newTrack != track { track = newTrack }

            let playing = head == "playing"
            if playing != isPlaying { isPlaying = playing }
            position = result.atIndex(8)?.doubleValue ?? 0
            positionDate = Date()

            // Don't fight the slider while the user is dragging it.
            if Date().timeIntervalSince(lastVolumeSend) > 0.6 {
                volume = Double(result.atIndex(9)?.int32Value ?? 50)
            }
            shuffling = result.atIndex(10)?.booleanValue ?? false
            repeating = result.atIndex(11)?.booleanValue ?? false

            loadArtwork(newTrack.artworkURL)
        }
    }

    private func loadArtwork(_ urlString: String) {
        guard urlString != artworkURLLoaded else { return }
        artworkURLLoaded = urlString
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            artwork = nil
            palette = .fallback
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            let palette = Palette.from(image)
            DispatchQueue.main.async {
                guard let self, self.artworkURLLoaded == urlString else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.artwork = image
                    self.palette = palette
                }
            }
        }.resume()
    }

    // MARK: - Commands

    private func send(_ command: String, refreshAfter delay: Double? = 0.2) {
        guard Self.spotifyIsRunning() else { return }
        runner.run("if application \"Spotify\" is running then tell application \"Spotify\" to \(command)") {
            [weak self] _, code in
            if code == -1743 { self?.permissionDenied = true }
        }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    func togglePlay() {
        position = currentPosition()
        positionDate = Date()
        isPlaying.toggle()
        send("playpause")
    }

    func next() { send("next track", refreshAfter: 0.35) }

    func previous() { send("previous track", refreshAfter: 0.35) }

    func seek(to seconds: Double) {
        position = seconds
        positionDate = Date()
        send("set player position to \(String(format: "%.2f", seconds))")
    }

    func setVolume(_ value: Double, final: Bool) {
        volume = value
        let now = Date()
        guard final || now.timeIntervalSince(lastVolumeSend) > 0.08 else { return }
        lastVolumeSend = now
        send("set sound volume to \(Int(value.rounded()))", refreshAfter: nil)
    }

    func toggleShuffle() {
        shuffling.toggle()
        send("set shuffling to \(shuffling)")
    }

    func toggleRepeat() {
        repeating.toggle()
        send("set repeating to \(repeating)")
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
