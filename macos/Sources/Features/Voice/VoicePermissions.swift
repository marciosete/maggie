import AppKit
import AVFoundation
import Foundation
import OSLog
import Speech

/// What macOS has to allow before the voice works in full: the microphone, to talk, and
/// speech recognition, for the Mac alone to hear "hey Maggie" and "unmute" while the
/// voice is muted or paused.
///
/// macOS asks the user once, the first time the app asks, and never again on its own: a
/// prompt declined, or dismissed by the Escape key, leaves the answer "denied" until the
/// user changes it in System Settings or the answer is reset. An update can't ask again
/// either. The answer is kept against the app's bundle id and its code signature, so an
/// update signed like the last release keeps it, and a build signed any other way under
/// the same bundle id (a local build installed over the official app, say) starts over,
/// or is refused while the old answer stands. `reset` clears the answer so the app can
/// ask afresh, which is the way out of both.
enum VoicePermission: CaseIterable, Hashable {
    case microphone
    case speechRecognition

    enum State: Equatable {
        /// macOS hasn't asked; `request` shows the prompt.
        case notAsked
        case allowed

        /// Declined or dismissed. macOS won't ask again; the user turns it on in System
        /// Settings, or the answer is reset and asked for afresh.
        case denied

        /// A device-management profile or parental control forbids it.
        case restricted

        var label: String {
            switch self {
            case .notAsked: return "Not asked yet"
            case .allowed: return "Allowed"
            case .denied: return "Not allowed"
            case .restricted: return "Restricted"
            }
        }
    }

    /// What the user does from here.
    enum Action: Equatable {
        /// Show the macOS prompt.
        case request

        /// macOS won't prompt; open System Settings at the right pane.
        case openSettings
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "VoicePermission"
    )

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech recognition"
        }
    }

    /// What it is for, in Maggie.
    var purpose: String {
        switch self {
        case .microphone:
            return "To hear you."
        case .speechRecognition:
            return "To hear \"hey Maggie\" and \"unmute\" on the Mac itself, without GPT-Live, while the voice is muted or paused."
        }
    }

    /// The service's name to `tccutil`.
    var tccService: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "SpeechRecognition"
        }
    }

    /// System Settings, open at the service's pane under Privacy & Security.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// The answer as macOS has it now.
    var state: State {
        switch self {
        case .microphone:
            return Self.state(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            return Self.state(SFSpeechRecognizer.authorizationStatus())
        }
    }

    static func state(_ status: AVAuthorizationStatus) -> State {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static func state(_ status: SFSpeechRecognizerAuthorizationStatus) -> State {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    /// The answer, asking the user if macOS hasn't yet. Call it while the user is at the
    /// Mac: the prompt is theirs to answer, and one they don't see is one they can't allow.
    func request() async -> State {
        guard state == .notAsked else { return state }
        switch self {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        let answer = state
        Self.logger.info("\(self.title, privacy: .public): \(answer.label, privacy: .public)")
        return answer
    }

    /// What a control for the permission does in `state`: asks, or sends the user to
    /// System Settings when macOS won't ask again. Allowed, there is nothing to do.
    static func action(for state: State) -> Action? {
        switch state {
        case .notAsked: return .request
        case .denied, .restricted: return .openSettings
        case .allowed: return nil
        }
    }

    /// The command that clears macOS's answer for `bundleID`, so the app can ask again:
    /// `tccutil reset <service> <bundle id>`. It needs no privileges for the user's own
    /// answers.
    static func resetCommand(for permission: VoicePermission, bundleID: String) -> [String] {
        ["/usr/bin/tccutil", "reset", permission.tccService, bundleID]
    }

    /// Clears macOS's answer for this app, so the next `request` asks afresh. The way out
    /// of a declined prompt, and of an answer kept for a signature this build no longer
    /// has.
    func reset(bundleID: String = Bundle.main.bundleIdentifier ?? "") throws {
        let command = Self.resetCommand(for: self, bundleID: bundleID)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ResetFailure(status: process.terminationStatus) }
        Self.logger.info("\(self.title, privacy: .public): answer reset")
    }

    /// Clears the answer and asks again, in one go.
    func resetAndRequest() async throws -> State {
        try reset()
        return await request()
    }

    struct ResetFailure: Error, LocalizedError {
        let status: Int32
        var errorDescription: String? { "tccutil failed (status \(status))" }
    }

    /// What the user is told about the permission in `state`, and what to do next.
    func guidance(for state: State, appName: String = VoicePermission.appName) -> String {
        switch (self, state) {
        case (.microphone, .notAsked):
            return "macOS will ask when the voice starts, or ask now."
        case (.speechRecognition, .notAsked):
            return "macOS will ask when the voice starts, or ask now. Without it, \"hey Maggie\" and \"unmute\" aren't heard; a click still works."
        case (_, .allowed):
            return "Allowed. If \(appName) is listed as allowed but nothing is heard, the answer may be for an earlier signature of the app: Ask Again clears it and asks afresh."
        case (.microphone, .denied):
            return "Turn on \(appName) under Microphone in System Settings › Privacy & Security, or Ask Again to clear the answer and be asked afresh."
        case (.speechRecognition, .denied):
            return "Turn on \(appName) under Speech Recognition in System Settings › Privacy & Security, or Ask Again to clear the answer and be asked afresh. Without it, say nothing to wake the voice: click the microphone instead."
        case (_, .restricted):
            return "A management profile or parental controls forbid it on this Mac."
        }
    }

    /// What the voice says, once, when it can't listen for its wake phrases.
    static func wakeProblem(for state: State, appName: String = VoicePermission.appName) -> String? {
        switch state {
        case .allowed, .notAsked: return nil
        case .denied:
            return "Speech recognition isn't allowed, so \"hey Maggie\" and \"unmute\" won't be heard; click the microphone instead. Allow \(appName) under Speech Recognition in System Settings › Privacy & Security, or ask again in Settings › Voice."
        case .restricted:
            return "Speech recognition is restricted on this Mac, so \"hey Maggie\" and \"unmute\" won't be heard; click the microphone instead."
        }
    }

    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Maggie"
    }

    /// Opens System Settings at the permission's pane.
    func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
