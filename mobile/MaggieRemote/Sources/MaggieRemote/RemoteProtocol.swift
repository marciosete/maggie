import Foundation

/// The wire protocol between Maggie on the Mac (the host) and Maggie Mobile (the client).
///
/// One WebSocket per device, over TLS with the Mac's certificate pinned. Text frames carry
/// one JSON message each, `{"version": 1, "kind": "...", "body": {...}}`. Binary frames
/// carry terminal bytes (`RemoteFrame`).
public enum RemoteProtocol {
    /// Bumped when either side would misread the other. `welcome` and `hello` carry it so
    /// the older side can ask to be updated rather than fail silently.
    public static let version = 1

    public static let defaultPort: UInt16 = 7788

    /// How long a connection has to say `hello` (or `pair`) once its handshake is done
    /// before the host closes it.
    public static let helloTimeout: TimeInterval = 5
}

/// A message the device sends the Mac.
public enum ClientMessage: Equatable, Sendable {
    /// The first message on a pairing connection, with the code the Mac shows.
    case pair(PairRequest)

    /// The first message on every other connection.
    case hello(Hello)

    /// Send the sidebar now and whenever it changes.
    case subscribeSidebar

    /// Start mirroring a session's terminal: `sessionOpened`, then a snapshot frame, then
    /// output frames.
    case openSession(SessionRef)

    /// Stop mirroring a session. The session keeps running on the Mac.
    case leaveSession(SessionRef)

    /// Close the session's tab on the Mac, as its close button does.
    case closeSession(CloseSession)

    /// Open a session in one of the Mac's folders, as New Session there does.
    case newSession(NewSession)

    /// Bring the session's tab to the front on the Mac.
    case focusSession(SessionRef)

    /// Send a fresh snapshot of a session whose mirror went wrong.
    case resyncSession(SessionRef)

    /// The device's Apple Push Notification service token.
    case registerPush(RegisterPush)

    case ping(Ping)

    /// Send the session board once, and again after each `moveCard`.
    case fetchBoard(FetchBoard)

    /// Move a card to another column of the board, at its end.
    case moveCard(MoveCard)

    /// Send the usage summary once.
    case fetchUsage

    /// Give a session a title, as renaming its tab does; empty goes back to the
    /// terminal's own.
    case renameSession(RenameSession)

    /// Send the last lines a session shows, for a preview.
    case peekSession(SessionRef)

    /// Size a session's terminal to what the device shows at its text size, so lines
    /// wrap at the device's edge; no size gives the Mac its own size back. Needs the
    /// `fitSession` capability.
    case fitSession(FitSession)

    /// List the folders inside one under the Mac's home folder for devices. Needs the
    /// `homeFolder` capability.
    case listFolders(ListFolders)

    /// Make this device the voice's handset: its microphone and speaker carry the
    /// conversation with Maggie's voice, which starts if it is off. Audio then travels in
    /// `voiceInput` and `voiceOutput` frames on `RemoteProtocol.voiceStream`. Needs the
    /// `voice` capability.
    case startVoice(StartVoice)

    /// Stop being the handset: the Mac's own microphone and speaker take over, or the
    /// voice stops altogether when asked.
    case stopVoice(StopVoice)

    /// Mute or unmute the handset's microphone, Mac side; the session keeps running.
    case muteVoice(MuteVoice)

    /// Send the voice's state now, and whenever it changes.
    case subscribeVoice
}

/// A message the Mac sends the device.
public enum HostMessage: Equatable, Sendable {
    /// The answer to `pair`: the token to say `hello` with from now on.
    case paired(Paired)

    /// The answer to a valid `hello`.
    case welcome(Welcome)

    case sidebar(SidebarSnapshot)

    /// A session is now mirrored on `stream`; its snapshot frame follows.
    case sessionOpened(SessionOpened)

    /// A mirrored session ended or a request about it was refused.
    case sessionClosed(SessionClosed)

    /// The session `newSession` opened.
    case sessionCreated(SessionCreated)

    case error(RemoteError)

    case pong(Ping)

    case board(BoardSnapshot)

    case usage(RemoteUsageReport)

    case sessionPeek(SessionPeek)

    /// The answer to `listFolders`.
    case folders(FolderListing)

    /// The session was used on the Mac, which took back the size `fitSession` asked
    /// for. The device shows the Mac's size until it asks again.
    case fitReleased(SessionRef)

    /// What the voice is doing, sent on change while subscribed.
    case voiceState(VoiceState)

    /// Something said in the voice conversation, as it is settled: by the user, by the
    /// voice, or by Maggie.
    case voiceTurn(VoiceTurnMessage)
}

// MARK: - Payloads

public struct PairRequest: Codable, Equatable, Sendable {
    /// The one-time code shown on the Mac and carried in its QR code.
    public var code: String
    public var deviceName: String

    /// The device's public key, kept by the Mac for later use. Optional in version 1.
    public var devicePublicKey: String?
    public var protocolVersion: Int

    public init(code: String, deviceName: String, devicePublicKey: String? = nil, protocolVersion: Int = RemoteProtocol.version) {
        self.code = code
        self.deviceName = deviceName
        self.devicePublicKey = devicePublicKey
        self.protocolVersion = protocolVersion
    }
}

public struct Paired: Codable, Equatable, Sendable {
    /// The secret the device says `hello` with. The Mac keeps only its hash.
    public var deviceToken: String
    public var deviceID: String
    public var hostName: String

    public init(deviceToken: String, deviceID: String, hostName: String) {
        self.deviceToken = deviceToken
        self.deviceID = deviceID
        self.hostName = hostName
    }
}

public struct Hello: Codable, Equatable, Sendable {
    public var deviceToken: String
    public var deviceName: String
    public var protocolVersion: Int

    public init(deviceToken: String, deviceName: String, protocolVersion: Int = RemoteProtocol.version) {
        self.deviceToken = deviceToken
        self.deviceName = deviceName
        self.protocolVersion = protocolVersion
    }
}

public struct Welcome: Codable, Equatable, Sendable {
    public var hostName: String
    public var protocolVersion: Int

    /// What this Mac supports beyond the basics, such as `push`. Unknown entries are ignored.
    public var capabilities: [String]

    public init(hostName: String, protocolVersion: Int = RemoteProtocol.version, capabilities: [String] = []) {
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct SessionRef: Codable, Equatable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct CloseSession: Codable, Equatable, Sendable {
    public var id: String

    /// Close even when a process is running, which the Mac otherwise asks about.
    public var force: Bool

    public init(id: String, force: Bool = false) {
        self.id = id
        self.force = force
    }
}

/// Where a new session opens: one of the Mac's sidebar folders, a folder from
/// `listFolders` (opened in the sidebar first), or with neither, the Mac's home folder
/// for devices, outside any sidebar folder.
public struct NewSession: Codable, Equatable, Sendable {
    public var folderID: String?
    public var path: String?

    /// The window it opens in (see `SidebarWindow.id`); none for the Mac's front one.
    public var windowID: String?

    public init(folderID: String? = nil, path: String? = nil, windowID: String? = nil) {
        self.folderID = folderID
        self.path = path
        self.windowID = windowID
    }
}

public struct SessionCreated: Codable, Equatable, Sendable {
    public var id: String

    /// The sidebar folder it opened in; none for the home folder.
    public var folderID: String?

    public init(id: String, folderID: String?) {
        self.id = id
        self.folderID = folderID
    }
}

/// Which board to send: one window's, as that window's board shows it on the Mac, or
/// with none, every window's sessions and cards.
public struct FetchBoard: Codable, Equatable, Sendable {
    /// See `SidebarWindow.id`.
    public var windowID: String?

    public init(windowID: String? = nil) {
        self.windowID = windowID
    }
}

/// The grid a device wants for a session, or none to give it back to the Mac.
public struct FitSession: Codable, Equatable, Sendable {
    public var id: String
    public var columns: UInt16?
    public var rows: UInt16?

    public init(id: String, columns: UInt16?, rows: UInt16?) {
        self.id = id
        self.columns = columns
        self.rows = rows
    }
}

public struct ListFolders: Codable, Equatable, Sendable {
    /// A path from an earlier listing; none for the home folder itself.
    public var path: String?

    public init(path: String? = nil) {
        self.path = path
    }
}

/// The folders directly inside one, under the Mac's home folder for devices.
public struct FolderListing: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var path: String

        /// Holds a repository, so a session there gets an agent like the sidebar's.
        public var isRepository: Bool

        public var id: String { path }

        public init(name: String, path: String, isRepository: Bool) {
            self.name = name
            self.path = path
            self.isRepository = isRepository
        }
    }

    public var path: String

    /// `path` as the Mac shows it, such as `~/projects`.
    public var displayPath: String

    /// The folder above, while still inside the home folder.
    public var parent: String?
    public var isRepository: Bool
    public var entries: [Entry]

    public init(path: String, displayPath: String, parent: String?, isRepository: Bool, entries: [Entry]) {
        self.path = path
        self.displayPath = displayPath
        self.parent = parent
        self.isRepository = isRepository
        self.entries = entries
    }
}

/// What `Welcome.capabilities` may list.
public enum RemoteCapability {
    public static let push = "push"
    public static let fitSession = "fitSession"
    public static let homeFolder = "homeFolder"

    /// The Mac can talk: `startVoice` and the voice frames.
    public static let voice = "voice"
}

// MARK: - Voice

extension RemoteProtocol {
    /// The stream number voice frames carry. No session's mirror has it.
    public static let voiceStream: UInt32 = .max

    /// Voice audio is 16-bit little-endian mono PCM at this rate, both ways, in frames
    /// of about a tenth of a second. The handset keeps sending while it listens, silence
    /// included: GPT-Live's clock runs on it.
    public static let voiceSampleRate = 24_000
}

public struct StartVoice: Codable, Equatable, Sendable {
    /// The device's name, shown on the Mac while it is the handset.
    public var deviceName: String

    public init(deviceName: String) {
        self.deviceName = deviceName
    }
}

public struct StopVoice: Codable, Equatable, Sendable {
    /// Stop the voice altogether rather than hand it back to the Mac.
    public var endsVoice: Bool

    public init(endsVoice: Bool = false) {
        self.endsVoice = endsVoice
    }
}

public struct MuteVoice: Codable, Equatable, Sendable {
    public var muted: Bool

    public init(muted: Bool) {
        self.muted = muted
    }
}

/// What Maggie's voice is doing.
public struct VoiceState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case off
        case connecting

        /// Talking, or ready to.
        case live

        /// Closed to save money while the user was quiet; speech or a tap starts it again.
        case paused
        case failed
    }

    public var phase: Phase
    public var muted: Bool

    /// This device is the handset: it should send microphone frames and play output
    /// frames.
    public var isHandset: Bool

    /// The handset's name: this device, another device, or the Mac.
    public var handsetName: String

    /// Seconds billed since the voice was turned on.
    public var billedSeconds: Double
    public var userSpeaking: Bool
    public var assistantSpeaking: Bool

    /// The tool the backend is running, while it runs one.
    public var workingOn: String?

    /// Why it failed, while `phase` is `failed`.
    public var error: String?

    public init(
        phase: Phase,
        muted: Bool = false,
        isHandset: Bool = false,
        handsetName: String = "Mac",
        billedSeconds: Double = 0,
        userSpeaking: Bool = false,
        assistantSpeaking: Bool = false,
        workingOn: String? = nil,
        error: String? = nil
    ) {
        self.phase = phase
        self.muted = muted
        self.isHandset = isHandset
        self.handsetName = handsetName
        self.billedSeconds = billedSeconds
        self.userSpeaking = userSpeaking
        self.assistantSpeaking = assistantSpeaking
        self.workingOn = workingOn
        self.error = error
    }
}

public struct VoiceTurnMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant

        /// Maggie reporting on a session.
        case notice

        /// What a tool did.
        case tool
    }

    public var id: String
    public var role: Role
    public var text: String
    public var at: Date

    public init(id: String, role: Role, text: String, at: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }
}

public struct SessionOpened: Codable, Equatable, Sendable {
    public var id: String

    /// The binary frames for this session carry this number.
    public var stream: UInt32
    public var columns: UInt16
    public var rows: UInt16

    public init(id: String, stream: UInt32, columns: UInt16, rows: UInt16) {
        self.id = id
        self.stream = stream
        self.columns = columns
        self.rows = rows
    }
}

public struct SessionClosed: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The tab was closed, on the Mac or at the device's request.
        case closed

        /// The device asked to stop mirroring it.
        case left

        /// No session has this id.
        case notFound

        /// Closing was refused because a process is running; ask, then send `force`.
        case processRunning

        /// The connection fell too far behind; open it again.
        case overflow
    }

    public var id: String
    public var reason: Reason

    public init(id: String, reason: Reason) {
        self.id = id
        self.reason = reason
    }
}

public struct RegisterPush: Codable, Equatable, Sendable {
    public enum Environment: String, Codable, Sendable {
        case sandbox
        case production
    }

    /// The APNs device token, hex encoded.
    public var token: String
    public var environment: Environment

    public init(token: String, environment: Environment) {
        self.token = token
        self.environment = environment
    }
}

public struct Ping: Codable, Equatable, Sendable {
    /// Echoed back in `pong`, so the device can time the round trip.
    public var nonce: UInt64

    public init(nonce: UInt64) {
        self.nonce = nonce
    }
}

public struct RemoteError: Codable, Equatable, Sendable, Error {
    public enum Code: String, Codable, Sendable {
        /// The device token is unknown or was removed on the Mac.
        case unauthorized
        case pairingCodeInvalid
        case pairingCodeExpired
        case versionMismatch
        case notFound
        case badRequest
        case `internal`
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Coding

public enum RemoteProtocolError: Error, Equatable {
    /// A message kind this side doesn't know. The receiver ignores it; a newer peer
    /// may send kinds an older one doesn't understand.
    case unknownKind(String)
}

private enum EnvelopeKeys: String, CodingKey {
    case version
    case kind
    case body
}

extension ClientMessage: Codable {
    public var kind: String {
        switch self {
        case .pair: return "pair"
        case .hello: return "hello"
        case .subscribeSidebar: return "subscribeSidebar"
        case .openSession: return "openSession"
        case .leaveSession: return "leaveSession"
        case .closeSession: return "closeSession"
        case .newSession: return "newSession"
        case .focusSession: return "focusSession"
        case .resyncSession: return "resyncSession"
        case .registerPush: return "registerPush"
        case .ping: return "ping"
        case .fetchBoard: return "fetchBoard"
        case .moveCard: return "moveCard"
        case .fetchUsage: return "fetchUsage"
        case .renameSession: return "renameSession"
        case .peekSession: return "peekSession"
        case .fitSession: return "fitSession"
        case .listFolders: return "listFolders"
        case .startVoice: return "startVoice"
        case .stopVoice: return "stopVoice"
        case .muteVoice: return "muteVoice"
        case .subscribeVoice: return "subscribeVoice"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EnvelopeKeys.self)
        try container.encode(RemoteProtocol.version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .pair(let body): try container.encode(body, forKey: .body)
        case .hello(let body): try container.encode(body, forKey: .body)
        case .subscribeSidebar: break
        case .openSession(let body): try container.encode(body, forKey: .body)
        case .leaveSession(let body): try container.encode(body, forKey: .body)
        case .closeSession(let body): try container.encode(body, forKey: .body)
        case .newSession(let body): try container.encode(body, forKey: .body)
        case .focusSession(let body): try container.encode(body, forKey: .body)
        case .resyncSession(let body): try container.encode(body, forKey: .body)
        case .registerPush(let body): try container.encode(body, forKey: .body)
        case .ping(let body): try container.encode(body, forKey: .body)
        case .fetchBoard(let body): try container.encode(body, forKey: .body)
        case .fetchUsage: break
        case .moveCard(let body): try container.encode(body, forKey: .body)
        case .renameSession(let body): try container.encode(body, forKey: .body)
        case .peekSession(let body): try container.encode(body, forKey: .body)
        case .fitSession(let body): try container.encode(body, forKey: .body)
        case .listFolders(let body): try container.encode(body, forKey: .body)
        case .startVoice(let body): try container.encode(body, forKey: .body)
        case .stopVoice(let body): try container.encode(body, forKey: .body)
        case .muteVoice(let body): try container.encode(body, forKey: .body)
        case .subscribeVoice: break
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EnvelopeKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "pair": self = .pair(try container.decode(PairRequest.self, forKey: .body))
        case "hello": self = .hello(try container.decode(Hello.self, forKey: .body))
        case "subscribeSidebar": self = .subscribeSidebar
        case "openSession": self = .openSession(try container.decode(SessionRef.self, forKey: .body))
        case "leaveSession": self = .leaveSession(try container.decode(SessionRef.self, forKey: .body))
        case "closeSession": self = .closeSession(try container.decode(CloseSession.self, forKey: .body))
        case "newSession": self = .newSession(try container.decode(NewSession.self, forKey: .body))
        case "focusSession": self = .focusSession(try container.decode(SessionRef.self, forKey: .body))
        case "resyncSession": self = .resyncSession(try container.decode(SessionRef.self, forKey: .body))
        case "registerPush": self = .registerPush(try container.decode(RegisterPush.self, forKey: .body))
        case "ping": self = .ping(try container.decode(Ping.self, forKey: .body))
        // A device that knows only one board sends no body.
        case "fetchBoard": self = .fetchBoard(try container.decodeIfPresent(FetchBoard.self, forKey: .body) ?? FetchBoard())
        case "moveCard": self = .moveCard(try container.decode(MoveCard.self, forKey: .body))
        case "fetchUsage": self = .fetchUsage
        case "renameSession": self = .renameSession(try container.decode(RenameSession.self, forKey: .body))
        case "peekSession": self = .peekSession(try container.decode(SessionRef.self, forKey: .body))
        case "fitSession": self = .fitSession(try container.decode(FitSession.self, forKey: .body))
        case "listFolders": self = .listFolders(try container.decode(ListFolders.self, forKey: .body))
        case "startVoice": self = .startVoice(try container.decode(StartVoice.self, forKey: .body))
        case "stopVoice": self = .stopVoice(try container.decode(StopVoice.self, forKey: .body))
        case "muteVoice": self = .muteVoice(try container.decode(MuteVoice.self, forKey: .body))
        case "subscribeVoice": self = .subscribeVoice
        default: throw RemoteProtocolError.unknownKind(kind)
        }
    }
}

extension HostMessage: Codable {
    public var kind: String {
        switch self {
        case .paired: return "paired"
        case .welcome: return "welcome"
        case .sidebar: return "sidebar"
        case .sessionOpened: return "sessionOpened"
        case .sessionClosed: return "sessionClosed"
        case .sessionCreated: return "sessionCreated"
        case .error: return "error"
        case .pong: return "pong"
        case .board: return "board"
        case .usage: return "usage"
        case .sessionPeek: return "sessionPeek"
        case .folders: return "folders"
        case .fitReleased: return "fitReleased"
        case .voiceState: return "voiceState"
        case .voiceTurn: return "voiceTurn"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EnvelopeKeys.self)
        try container.encode(RemoteProtocol.version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .paired(let body): try container.encode(body, forKey: .body)
        case .welcome(let body): try container.encode(body, forKey: .body)
        case .sidebar(let body): try container.encode(body, forKey: .body)
        case .sessionOpened(let body): try container.encode(body, forKey: .body)
        case .sessionClosed(let body): try container.encode(body, forKey: .body)
        case .sessionCreated(let body): try container.encode(body, forKey: .body)
        case .error(let body): try container.encode(body, forKey: .body)
        case .pong(let body): try container.encode(body, forKey: .body)
        case .board(let body): try container.encode(body, forKey: .body)
        case .usage(let body): try container.encode(body, forKey: .body)
        case .sessionPeek(let body): try container.encode(body, forKey: .body)
        case .folders(let body): try container.encode(body, forKey: .body)
        case .fitReleased(let body): try container.encode(body, forKey: .body)
        case .voiceState(let body): try container.encode(body, forKey: .body)
        case .voiceTurn(let body): try container.encode(body, forKey: .body)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EnvelopeKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "paired": self = .paired(try container.decode(Paired.self, forKey: .body))
        case "welcome": self = .welcome(try container.decode(Welcome.self, forKey: .body))
        case "sidebar": self = .sidebar(try container.decode(SidebarSnapshot.self, forKey: .body))
        case "sessionOpened": self = .sessionOpened(try container.decode(SessionOpened.self, forKey: .body))
        case "sessionClosed": self = .sessionClosed(try container.decode(SessionClosed.self, forKey: .body))
        case "sessionCreated": self = .sessionCreated(try container.decode(SessionCreated.self, forKey: .body))
        case "error": self = .error(try container.decode(RemoteError.self, forKey: .body))
        case "pong": self = .pong(try container.decode(Ping.self, forKey: .body))
        case "board": self = .board(try container.decode(BoardSnapshot.self, forKey: .body))
        case "usage": self = .usage(try container.decode(RemoteUsageReport.self, forKey: .body))
        case "sessionPeek": self = .sessionPeek(try container.decode(SessionPeek.self, forKey: .body))
        case "folders": self = .folders(try container.decode(FolderListing.self, forKey: .body))
        case "fitReleased": self = .fitReleased(try container.decode(SessionRef.self, forKey: .body))
        case "voiceState": self = .voiceState(try container.decode(VoiceState.self, forKey: .body))
        case "voiceTurn": self = .voiceTurn(try container.decode(VoiceTurnMessage.self, forKey: .body))
        default: throw RemoteProtocolError.unknownKind(kind)
        }
    }
}

/// JSON coding with the settings both sides use.
public enum RemoteCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}
