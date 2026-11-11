import Foundation

/// Start at login through a LaunchAgent that runs this build of the app.
/// A plain file in ~/Library/LaunchAgents keeps working across rebuilds, because it points
/// at the executable's path rather than at a registered copy of the bundle.
enum LoginItem {
    static let label = "local.notchify.login"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var executable: String { Bundle.main.executablePath ?? "" }

    static var isEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return false }
        return arguments.first == executable
    }

    /// Takes effect at the next login; the running app is left alone either way.
    static func setEnabled(_ enabled: Bool) {
        guard enabled else {
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // Without this launchd treats the widget as a background job and throttles it.
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: plistURL, options: .atomic)
    }
}
