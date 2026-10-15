import AppKit
import CryptoKit

/// Push notifications to paired devices when a session needs them: it started waiting
/// for an answer, or it finished working. Sent from this Mac straight to the Apple Push
/// Notification service with the developer's .p8 key; no server in between.
///
/// Its own switch in Settings › Mobile, apart from the Mac's own bell notifications.
@MainActor
final class RemotePush: ObservableObject {
    private enum Keys {
        static let enabled = "RemotePushEnabled"
        static let keyID = "RemotePushKeyID"
        static let teamID = "RemotePushTeamID"
        static let topic = "RemotePushTopic"
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.ghostty.set(isEnabled, forKey: Keys.enabled)
            restart()
        }
    }

    @Published var keyID: String {
        didSet {
            UserDefaults.ghostty.set(keyID, forKey: Keys.keyID)
            credentials = nil
        }
    }

    @Published var teamID: String {
        didSet {
            UserDefaults.ghostty.set(teamID, forKey: Keys.teamID)
            credentials = nil
        }
    }

    /// The app's bundle ID, which APNs calls the topic.
    @Published var topic: String {
        didSet { UserDefaults.ghostty.set(topic, forKey: Keys.topic) }
    }

    @Published private(set) var hasKey: Bool
    @Published private(set) var lastResult: String?

    private let devices: RemoteDeviceStore
    private let ids: RemoteSessionIDs
    private let session: URLSession
    private let keyFile: URL
    private var timer: Timer?
    private var lights: [ObjectIdentifier: ClaudeCodeLight] = [:]
    private var rules = RemotePushRules()
    private var credentials: RemotePushCredentials?

    static let defaultTopic = "com.marciosete.maggie.mobile"

    init(devices: RemoteDeviceStore, ids: RemoteSessionIDs, session: URLSession = .shared, keyFile: URL = RemoteService.directory.appendingPathComponent("AuthKey.p8")) {
        let defaults = UserDefaults.ghostty
        self.devices = devices
        self.ids = ids
        self.session = session
        self.keyFile = keyFile
        isEnabled = defaults.bool(forKey: Keys.enabled)
        keyID = defaults.string(forKey: Keys.keyID) ?? ""
        teamID = defaults.string(forKey: Keys.teamID) ?? ""
        topic = defaults.string(forKey: Keys.topic) ?? Self.defaultTopic
        hasKey = FileManager.default.fileExists(atPath: keyFile.path)
        restart()
    }

    var isConfigured: Bool {
        hasKey && !keyID.trimmingCharacters(in: .whitespaces).isEmpty && !teamID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Keeps a copy of the .p8 key, readable only by this user.
    func importKey(from url: URL) throws {
        let pem = try String(contentsOf: url, encoding: .utf8)
        _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
        try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pem.write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        hasKey = true
        credentials = nil
    }

    private func restart() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        lights = currentLights()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Every tab's light, by window.
    private func currentLights() -> [ObjectIdentifier: ClaudeCodeLight] {
        var result: [ObjectIdentifier: ClaudeCodeLight] = [:]
        for window in NSApp.windows.compactMap({ $0 as? TerminalWindow }) {
            if let light = window.claudeCodeState?.light { result[ObjectIdentifier(window)] = light }
        }
        return result
    }

    private func check() {
        let windows = NSApp.windows.compactMap { $0 as? TerminalWindow }
        let now = Date()
        for window in windows {
            let key = ObjectIdentifier(window)
            let new = window.claudeCodeState?.light
            let old = lights[key]
            lights[key] = new
            let id = ids.id(for: window)
            guard let notice = rules.notice(from: old, to: new, session: id, at: now) else { continue }
            send(notice, title: window.sessionTitle ?? window.title)
        }
        let live = Set(windows.map(ObjectIdentifier.init))
        lights = lights.filter { live.contains($0.key) }
    }

    /// Sends `notice` to every device with a push token.
    func send(_ notice: RemotePushRules.Notice, title: String) {
        guard isConfigured else { return }
        for device in devices.devices {
            guard let token = device.pushToken else { continue }
            Task { await deliver(notice, title: title, token: token, environment: device.pushEnvironment ?? .production, deviceID: device.id) }
        }
    }

    private func deliver(_ notice: RemotePushRules.Notice, title: String, token: String, environment: RegisterPush.Environment, deviceID: String) async {
        do {
            let jwt = try currentJWT()
            let request = RemotePushRequest.make(notice: notice, title: title, token: token, environment: environment, topic: topic, jwt: jwt)
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                lastResult = "Sent \(Date().formatted(date: .omitted, time: .shortened))"
            case 410:
                // The app was removed from the device, or its token replaced.
                devices.update(id: deviceID) {
                    $0.pushToken = nil
                    $0.pushEnvironment = nil
                }
                lastResult = "A device's push token expired"
            default:
                lastResult = "APNs answered \(status)"
                RemoteService.logger.error("APNs answered \(status)")
            }
        } catch {
            lastResult = error.localizedDescription
            RemoteService.logger.error("push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentJWT() throws -> String {
        if let credentials, let jwt = credentials.validJWT(at: Date()) { return jwt }
        let pem = try String(contentsOf: keyFile, encoding: .utf8)
        var fresh = RemotePushCredentials(
            key: try P256.Signing.PrivateKey(pemRepresentation: pem),
            keyID: keyID.trimmingCharacters(in: .whitespaces),
            teamID: teamID.trimmingCharacters(in: .whitespaces))
        let jwt = try fresh.jwt(at: Date())
        credentials = fresh
        return jwt
    }
}

/// When a session's light change is worth a push, at most one per session every 30
/// seconds so a flickering session doesn't buzz the phone.
struct RemotePushRules {
    struct Notice: Equatable {
        let session: String
        let light: ClaudeCodeLight
    }

    static let interval: TimeInterval = 30
    private var lastSent: [String: Date] = [:]

    mutating func notice(from old: ClaudeCodeLight?, to new: ClaudeCodeLight?, session: String, at now: Date) -> Notice? {
        guard let new, let old, new != old else { return nil }
        let worthIt = new == .waiting || (old == .working && [.pending, .unlanded, .clean].contains(new))
        guard worthIt else { return nil }
        if let last = lastSent[session], now.timeIntervalSince(last) < Self.interval { return nil }
        lastSent[session] = now
        return Notice(session: session, light: new)
    }
}

/// The signing key and the token signed with it. APNs wants a fresh token at least
/// hourly and refuses one refreshed more than every 20 minutes, so it is kept 50.
struct RemotePushCredentials {
    let key: P256.Signing.PrivateKey
    let keyID: String
    let teamID: String
    private var issued: (jwt: String, at: Date)?

    init(key: P256.Signing.PrivateKey, keyID: String, teamID: String) {
        self.key = key
        self.keyID = keyID
        self.teamID = teamID
    }

    static let lifetime: TimeInterval = 50 * 60

    func validJWT(at now: Date) -> String? {
        guard let issued, now.timeIntervalSince(issued.at) < Self.lifetime else { return nil }
        return issued.jwt
    }

    /// An ES256 JSON Web Token as APNs asks: the key ID in the header, the team as
    /// issuer.
    mutating func jwt(at now: Date) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(now.timeIntervalSince1970)], options: [.sortedKeys])
        let signingInput = Self.base64URL(header) + "." + Self.base64URL(claims)
        let signature = try key.signature(for: Data(signingInput.utf8))
        let jwt = signingInput + "." + Self.base64URL(signature.rawRepresentation)
        issued = (jwt, now)
        return jwt
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The HTTP/2 request APNs takes for one notification.
enum RemotePushRequest {
    static func host(for environment: RegisterPush.Environment) -> String {
        environment == .sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
    }

    static func make(notice: RemotePushRules.Notice, title: String, token: String, environment: RegisterPush.Environment, topic: String, jwt: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(host(for: environment))/3/device/\(token)")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(notice.session, forHTTPHeaderField: "apns-collapse-id")
        let body: [String: Any] = [
            "aps": [
                "alert": ["title": title, "body": body(for: notice.light)],
                "sound": "default",
                "thread-id": notice.session,
            ],
            "session": notice.session,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func body(for light: ClaudeCodeLight) -> String {
        light == .waiting ? "Waiting for you" : "Done"
    }
}
