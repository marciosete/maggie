import Foundation
import OSLog

/// OpenAI's API key, for GPT-Live.
///
/// The key is kept in `~/.config/ghostty/openai-api-key`, readable only by its owner, as
/// the ElevenLabs key is (see `ElevenLabs`): every build of the app is signed differently,
/// so the keychain would ask for the password again for each.
enum OpenAI {
    static var apiKeyFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/ghostty/openai-api-key")
    }

    /// The API key, from its file, or from `OPENAI_API_KEY` for an app started from a shell.
    static func apiKey() -> String? {
        let fromFile = (try? String(contentsOf: apiKeyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromFile, !fromFile.isEmpty { return fromFile }
        let variable = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return variable?.isEmpty == false ? variable : nil
    }

    /// Writes the key to its file, for the owner only.
    static func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = apiKeyFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: apiKeyFile)
            return
        }
        try Data(trimmed.utf8).write(to: apiKeyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: apiKeyFile.path)
    }
}

/// One event GPT-Live sends over its WebSocket, parsed from its JSON. Events the voice
/// doesn't act on come through as `other`, with their type, so nothing is lost in a log.
///
/// A backend (Responses delegation) event arrives wrapped in `response.event`; the ones
/// that matter are unwrapped here: a finished function call, a finished message, and the
/// end of a response.
enum OpenAILiveEvent: Equatable {
    case started(sessionID: String, expiresAt: Date?)
    case updated
    case delegationCreated(id: String, target: String)

    /// The backend asked for a function to be run. `arguments` is JSON.
    case functionCall(delegationID: String, callID: String, name: String, arguments: String)

    /// The backend finished a message. GPT-Live says it; this is its text.
    case backendMessage(delegationID: String, text: String)

    /// A backend response ended. Function calls it made are complete and can be answered.
    case backendCompleted(delegationID: String, responseID: String?)

    /// A fragment of what the user said, or what GPT-Live said.
    case inputTranscript(String)
    case outputTranscript(String)

    /// Speech, as 16-bit mono PCM at the session's rate.
    case outputAudio(Data)

    /// Cumulative seconds, and how full the context window is.
    case usage(seconds: Double, contextRatio: Double?)

    /// An append was taken into the conversation: `kind` is commentary, thinking or
    /// instructions.
    case appended(kind: String, clientEventID: String?)
    case inputMuted(Bool)
    case closed(reason: String, seconds: Double?)
    case error(code: String?, message: String, clientEventID: String?)
    case other(String)

    /// The event in `json`, or nil for JSON without a type.
    static func parse(_ json: [String: Any]) -> OpenAILiveEvent? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "session.started":
            let session = json["session"] as? [String: Any] ?? [:]
            let expires = (session["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return .started(sessionID: session["id"] as? String ?? "", expiresAt: expires)
        case "session.updated":
            return .updated
        case "session.delegation.created":
            let delegation = json["delegation"] as? [String: Any] ?? [:]
            return .delegationCreated(
                id: delegation["id"] as? String ?? "",
                target: delegation["target"] as? String ?? "")
        case "response.event":
            return backend(json)
        case "session.input_transcript.delta":
            return .inputTranscript(json["delta"] as? String ?? "")
        case "session.output_transcript.delta":
            return .outputTranscript(json["delta"] as? String ?? "")
        case "session.output_audio.delta":
            guard let base64 = json["delta"] as? String, let data = Data(base64Encoded: base64) else {
                return .other(type)
            }
            return .outputAudio(data)
        case "session.usage.updated":
            let usage = json["usage"] as? [String: Any] ?? [:]
            let window = json["context_window"] as? [String: Any] ?? [:]
            return .usage(seconds: usage["seconds"] as? Double ?? 0, contextRatio: window["usage_ratio"] as? Double)
        case "session.commentary.appended", "session.thinking.appended", "session.instructions.appended":
            let kind = type.split(separator: ".").dropFirst().first.map(String.init) ?? ""
            return .appended(kind: kind, clientEventID: json["client_event_id"] as? String)
        case "session.input_audio.muted":
            return .inputMuted(true)
        case "session.input_audio.unmuted":
            return .inputMuted(false)
        case "session.closed":
            let usage = json["usage"] as? [String: Any] ?? [:]
            return .closed(reason: json["reason"] as? String ?? "", seconds: usage["seconds"] as? Double)
        case "error":
            let error = json["error"] as? [String: Any] ?? [:]
            return .error(
                code: error["code"] as? String,
                message: error["message"] as? String ?? "GPT-Live error",
                clientEventID: error["client_event_id"] as? String)
        default:
            return .other(type)
        }
    }

    private static func backend(_ json: [String: Any]) -> OpenAILiveEvent {
        let delegationID = json["delegation_id"] as? String ?? ""
        guard let inner = json["event"] as? [String: Any], let type = inner["type"] as? String else {
            return .other("response.event")
        }
        switch type {
        case "response.output_item.done":
            let item = inner["item"] as? [String: Any] ?? [:]
            switch item["type"] as? String {
            case "function_call":
                return .functionCall(
                    delegationID: delegationID,
                    callID: item["call_id"] as? String ?? "",
                    name: item["name"] as? String ?? "",
                    arguments: item["arguments"] as? String ?? "{}")
            case "message":
                let parts = item["content"] as? [[String: Any]] ?? []
                let text = parts.compactMap { part -> String? in
                    guard part["type"] as? String == "output_text" else { return nil }
                    return part["text"] as? String
                }.joined(separator: "\n")
                return .backendMessage(delegationID: delegationID, text: text)
            default:
                return .other("response.event/\(type)")
            }
        case "response.completed", "response.incomplete", "response.failed":
            let response = inner["response"] as? [String: Any] ?? [:]
            return .backendCompleted(delegationID: delegationID, responseID: response["id"] as? String)
        default:
            return .other("response.event/\(type)")
        }
    }
}

/// A WebSocket to GPT-Live. Events arrive on the main thread, one at a time, in order.
/// Audio and commands go out as JSON text frames.
final class OpenAILiveSocket: NSObject, @unchecked Sendable {
    static let url = URL(string: "wss://api.openai.com/v1/live/sessions")!

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: OpenAILiveSocket.self)
    )

    /// Each parsed event, with its JSON for anything the parse leaves out.
    var onEvent: (@MainActor (OpenAILiveEvent, [String: Any]) -> Void)?

    /// The socket ended, with the failure that ended it, if it wasn't asked to close.
    var onClose: (@MainActor (Error?) -> Void)?

    private let apiKey: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var sent = 0

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Opens the socket. `session.start` must be the first thing sent.
    func connect() {
        var request = URLRequest(url: Self.url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        self.task = task
        task.resume()
        receive()
    }

    /// Sends `event` as JSON. Returns the event id given to it, for matching replies.
    @discardableResult
    func send(_ event: [String: Any]) -> String? {
        var event = event
        var id = event["event_id"] as? String
        if id == nil, let type = event["type"] as? String, type != "session.input_audio.append" {
            sent += 1
            id = "\(type.replacingOccurrences(of: ".", with: "_"))_\(sent)"
            event["event_id"] = id
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return nil }
        task?.send(.string(text)) { error in
            if let error, !self.closed {
                Self.logger.warning("send failed: \(String(describing: error), privacy: .public)")
            }
        }
        return id
    }

    func sendAudio(_ pcm: Data) {
        send(["type": "session.input_audio.append", "audio": pcm.base64EncodedString()])
    }

    /// Drops the socket. A graceful close sends `session.close` and waits for
    /// `session.closed` first; this is the end of it either way.
    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receive()
            case .failure(let error):
                self.ended(with: error)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = OpenAILiveEvent.parse(json) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onEvent?(event, json) }
        }
    }

    private func ended(with error: Error?) {
        let wasClosed = closed
        closed = true
        session?.invalidateAndCancel()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onClose?(wasClosed ? nil : error) }
        }
    }
}

extension OpenAILiveSocket: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Self.logger.info("socket closed: \(closeCode.rawValue) \(text, privacy: .public)")
        ended(with: closeCode == .normalClosure ? nil : SocketClosed(code: closeCode.rawValue, reason: text))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { ended(with: error) }
    }

    struct SocketClosed: Error, CustomStringConvertible {
        let code: Int
        let reason: String
        var description: String { "The connection closed (\(code)). \(reason)" }
    }
}
