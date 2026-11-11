import CoreAudio
import Foundation

/// Tells whether an app is sending sound to this Mac's audio output right now.
/// Spotify reports "playing" even when the music comes out of another device
/// (Spotify Connect), so this is how we tell the two apart. Needs no permission.
final class AudioOutputMonitor {
    var onChange: (() -> Void)?
    private(set) var isOutputting = false

    private let bundlePrefix: String
    private var watched: [AudioObjectID] = []
    private var listListener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    init(bundlePrefix: String) {
        self.bundlePrefix = bundlePrefix

        let listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
        let outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update() }
        self.listListener = listListener
        self.outputListener = outputListener

        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, listListener)
        rescan()
    }

    /// Safety net for a missed notification.
    func poll() {
        if watched.isEmpty { rescan() } else { update() }
    }

    private func rescan() {
        guard let outputListener else { return }
        var address = Self.address(kAudioProcessPropertyIsRunningOutput)
        for id in watched {
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, outputListener)
        }
        watched = Self.processObjects().filter { Self.bundleID(of: $0).hasPrefix(bundlePrefix) }
        for id in watched {
            AudioObjectAddPropertyListenerBlock(id, &address, .main, outputListener)
        }
        update()
    }

    private func update() {
        let now = watched.contains { Self.isRunningOutput($0) }
        guard now != isOutputting else { return }
        isOutputting = now
        onChange?()
    }

    // MARK: - CoreAudio plumbing

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func bundleID(of id: AudioObjectID) -> String {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }
}
