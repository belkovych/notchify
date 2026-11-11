import AppKit
import CryptoKit
import Network
import Security

/// A Spotify Connect device (TV, phone, this Mac, …).
struct ConnectDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    var isActive: Bool
    let isRestricted: Bool

    var symbol: String {
        switch type.lowercased() {
        case "computer": return "laptopcomputer"
        case "smartphone": return "iphone"
        case "tablet": return "ipad"
        case "tv", "stb", "castvideo": return "tv"
        case "avr": return "hifispeaker.2.fill"
        case "automobile": return "car.fill"
        case "gameconsole": return "gamecontroller.fill"
        default: return "hifispeaker.fill"
        }
    }
}

private enum ConnectError: Error {
    case notAuthorized
    case rejected // Spotify refused the code or the refresh token
    case premiumRequired
    case http(Int)
}

/// Lists Spotify Connect devices and moves playback between them through the Web API.
/// The desktop app's AppleScript interface knows nothing about devices, so this needs
/// the user's own Spotify app (Client ID) and a one-time login in the browser (PKCE).
final class SpotifyConnect: ObservableObject {
    enum Phase: Equatable { case needsClientID, needsLogin, waitingForBrowser, ready }

    static let port: UInt16 = 43917
    static let redirectURI = "http://127.0.0.1:\(port)/callback"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
    private static let scopes = "user-read-playback-state user-modify-playback-state"
    private static let clientIDKey = "spotifyClientID"

    @Published private(set) var phase: Phase
    @Published private(set) var devices: [ConnectDevice] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published private(set) var transferringID: String?

    /// Called after playback moved to another device.
    var onPlaybackMoved: (() -> Void)?

    var activeDevice: ConnectDevice? { devices.first { $0.isActive } }

    private var clientID: String? { UserDefaults.standard.string(forKey: Self.clientIDKey) }
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var refreshTask: Task<String, Error>?
    private var lastLoad = Date.distantPast
    private var isFake = false

    private var listener: NWListener?
    private var pending: (verifier: String, state: String)?
    private var loginTimeout: DispatchWorkItem?

    init() {
        if UserDefaults.standard.string(forKey: Self.clientIDKey) == nil {
            phase = .needsClientID
        } else {
            phase = TokenStore.read() == nil ? .needsLogin : .ready
        }

        // Debug: NOTCHIFY_FAKE_DEVICES=1 fills the list without talking to Spotify.
        if ProcessInfo.processInfo.environment["NOTCHIFY_FAKE_DEVICES"] == "1" {
            isFake = true
            phase = .ready
            devices = [
                ConnectDevice(id: "1", name: "MacBook Pro", type: "Computer", isActive: false, isRestricted: false),
                ConnectDevice(id: "2", name: "Телевізор у вітальні", type: "TV", isActive: true, isRestricted: false),
                ConnectDevice(id: "3", name: "iPhone", type: "Smartphone", isActive: false, isRestricted: false),
                ConnectDevice(id: "4", name: "Колонка на кухні", type: "Speaker", isActive: false, isRestricted: true),
            ]
        }
    }

    // MARK: - Setup

    /// Takes the Client ID from the clipboard: the panel never becomes key, so it can't host a text field.
    func pasteClientID() {
        let text = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            message = "У буфері обміну немає Client ID (це 32 символи)"
            return
        }
        UserDefaults.standard.set(text, forKey: Self.clientIDKey)
        message = nil
        phase = .needsLogin
    }

    func forgetClientID() {
        signOut()
        UserDefaults.standard.removeObject(forKey: Self.clientIDKey)
        phase = .needsClientID
    }

    func copyRedirectURI() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.redirectURI, forType: .string)
    }

    func signOut() {
        stopLogin()
        TokenStore.delete()
        accessToken = nil
        accessExpiry = .distantPast
        devices = []
        message = nil
        phase = clientID == nil ? .needsClientID : .needsLogin
    }

    // MARK: - Login (authorization code + PKCE, loopback redirect)

    func login() {
        guard let clientID else { return }
        stopLogin()

        let verifier = Self.randomString(64)
        let state = Self.randomString(24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        do {
            try startListener()
        } catch {
            message = "Не вдалося відкрити порт \(Self.port) для входу"
            return
        }
        pending = (verifier, state)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)

        message = nil
        phase = .waitingForBrowser

        let timeout = DispatchWorkItem { [weak self] in self?.cancelLogin() }
        loginTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeout)
    }

    func cancelLogin() {
        guard phase == .waitingForBrowser else { return }
        stopLogin()
        phase = .needsLogin
    }

    private func stopLogin() {
        loginTimeout?.cancel()
        loginTimeout = nil
        listener?.cancel()
        listener = nil
        pending = nil
    }

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: nothing outside this Mac can reach it.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed = state, let self, self.phase == .waitingForBrowser else { return }
            self.stopLogin()
            self.phase = .needsLogin
            self.message = "Порт \(Self.port) зайнятий — спробуйте ще раз"
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // "GET /callback?code=…&state=… HTTP/1.1"
            let parts = head.split(separator: " ", maxSplits: 2)
            let target = parts.count >= 2 ? String(parts[1]) : ""
            let (status, text) = self?.handleRedirect(target) ?? ("404 Not Found", "")

            let body = """
            <!doctype html><meta charset="utf-8"><title>Notchify</title>
            <body style="font: 17px -apple-system, sans-serif; background: #111; color: #eee; \
            display: grid; place-items: center; height: 100vh; margin: 0"><p>\(text)</p></body>
            """
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func handleRedirect(_ target: String) -> (status: String, text: String) {
        guard let pending,
              let components = URLComponents(string: "http://127.0.0.1" + target),
              components.path == "/callback" else {
            return ("404 Not Found", "Сторінку не знайдено.")
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        guard query["state"] == pending.state else {
            return ("400 Bad Request", "Цей запит надійшов не від Notchify.")
        }
        stopLogin()

        guard let code = query["code"] else {
            phase = .needsLogin
            message = "Доступ у браузері не надано"
            return ("200 OK", "Доступ не надано. Закрийте вкладку і спробуйте ще раз у Notchify.")
        }
        Task { @MainActor in
            do {
                let token = try await Self.tokenRequest([
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": Self.redirectURI,
                    "client_id": self.clientID ?? "",
                    "code_verifier": pending.verifier,
                ])
                self.store(token)
                self.phase = .ready
                await self.loadDevices()
            } catch {
                self.phase = .needsLogin
                self.message = "Spotify не прийняв вхід — перевірте Client ID і Redirect URI"
            }
        }
        return ("200 OK", "Notchify підключено до Spotify. Цю вкладку можна закрити.")
    }

    // MARK: - Devices

    func reload() {
        guard phase == .ready, !isFake else { return }
        Task { @MainActor in await self.loadDevices() }
    }

    /// Refresh unless the list is younger than `age` seconds.
    func reloadIfStale(after age: Double = 20) {
        if Date().timeIntervalSince(lastLoad) > age { reload() }
    }

    func transfer(to device: ConnectDevice) {
        guard phase == .ready, !isFake, transferringID == nil, !device.isActive, !device.isRestricted else {
            return
        }
        transferringID = device.id
        message = nil
        Task { @MainActor in
            do {
                _ = try await self.api("PUT", "/me/player", body: ["device_ids": [device.id]])
                for index in self.devices.indices {
                    self.devices[index].isActive = self.devices[index].id == device.id
                }
                self.onPlaybackMoved?()
                // Spotify needs a moment before the device list reflects the move.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.transferringID = nil
                self.onPlaybackMoved?()
                await self.loadDevices()
            } catch {
                self.transferringID = nil
                self.report(error, transferring: true)
            }
        }
    }

    @MainActor
    private func loadDevices() async {
        guard phase == .ready, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await api("GET", "/me/player/devices")
            let decoded = try JSONDecoder().decode(DevicesResponse.self, from: data)
            devices = decoded.devices.compactMap { device in
                guard let id = device.id else { return nil }
                return ConnectDevice(id: id, name: device.name, type: device.type,
                                     isActive: device.is_active, isRestricted: device.is_restricted)
            }
            lastLoad = Date()
            message = nil
        } catch {
            report(error, transferring: false)
        }
    }

    private func report(_ error: Error, transferring: Bool) {
        switch error {
        case ConnectError.notAuthorized, ConnectError.rejected:
            message = "Потрібно знову увійти в Spotify"
        case ConnectError.premiumRequired:
            message = "Перемикати пристрої можна лише зі Spotify Premium"
        case ConnectError.http(404) where transferring:
            message = "Пристрій зараз недоступний"
        case ConnectError.http(429):
            message = "Spotify просить зачекати — спробуйте за хвилину"
        case ConnectError.http(let status):
            message = "Помилка Spotify (\(status))"
        default:
            message = "Немає звʼязку зі Spotify"
        }
    }

    // MARK: - Web API

    private struct DevicesResponse: Decodable {
        struct Device: Decodable {
            let id: String?
            let name: String
            let type: String
            let is_active: Bool
            let is_restricted: Bool
        }
        let devices: [Device]
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private struct APIErrorResponse: Decodable {
        struct Body: Decodable { let reason: String? }
        let error: Body
    }

    @MainActor
    private func api(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        for attempt in 0..<2 {
            let token = try await validToken()
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
            request.httpMethod = method
            request.timeoutInterval = 8
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                accessToken = nil // expired early: refresh and retry once
                continue
            }
            guard (200..<300).contains(status) else {
                let reason = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.reason
                if status == 403, reason == "PREMIUM_REQUIRED" { throw ConnectError.premiumRequired }
                throw status == 401 ? ConnectError.notAuthorized : ConnectError.http(status)
            }
            return data
        }
        throw ConnectError.notAuthorized
    }

    @MainActor
    private func validToken() async throws -> String {
        if let accessToken, accessExpiry.timeIntervalSinceNow > 30 { return accessToken }
        // Refresh tokens rotate, so two refreshes must never run at once.
        if let refreshTask { return try await refreshTask.value }
        guard let clientID, let refreshToken = TokenStore.read() else {
            signOut()
            throw ConnectError.notAuthorized
        }
        let task = Task { @MainActor () throws -> String in
            defer { self.refreshTask = nil }
            do {
                let token = try await Self.tokenRequest([
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": clientID,
                ])
                self.store(token)
                return token.access_token
            } catch ConnectError.rejected {
                self.signOut()
                throw ConnectError.notAuthorized
            }
        }
        refreshTask = task
        return try await task.value
    }

    private func store(_ token: TokenResponse) {
        accessToken = token.access_token
        accessExpiry = Date().addingTimeInterval(token.expires_in)
        if let refreshToken = token.refresh_token { TokenStore.write(refreshToken) }
    }

    private static func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields
            .map { key, value in
                key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw (400..<500).contains(status) ? ConnectError.rejected : ConnectError.http(status)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

/// The refresh token lives in the login keychain, not in a plain file.
private enum TokenStore {
    private static let base: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "local.notchify.spotify",
        kSecAttrAccount: "refresh-token",
    ]

    static func read() -> String? {
        var query = base
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
