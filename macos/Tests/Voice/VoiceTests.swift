import AVFoundation
import Foundation
import Speech
import Testing
@testable import Ghostty

// MARK: - GPT-Live events

@Suite
struct OpenAILiveEventTests {
    private func parse(_ json: String) -> OpenAILiveEvent? {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return object.flatMap(OpenAILiveEvent.parse)
    }

    @Test func aStartedSessionCarriesItsExpiry() {
        let event = parse(#"{"type":"session.started","session":{"id":"live_1","expires_at":1792120858}}"#)
        #expect(event == .started(sessionID: "live_1", expiresAt: Date(timeIntervalSince1970: 1_792_120_858)))
    }

    @Test func aFinishedFunctionCallIsUnwrappedFromTheBackendEnvelope() {
        let event = parse(#"""
        {"type":"response.event","delegation_id":"item_1","event":{"type":"response.output_item.done",
         "item":{"type":"function_call","call_id":"call_9","name":"tell_session","arguments":"{\"session\":\"4\"}"}}}
        """#)
        #expect(event == .functionCall(delegationID: "item_1", callID: "call_9", name: "tell_session", arguments: #"{"session":"4"}"#))
    }

    @Test func aFinishedMessageAndACompletedResponseAreUnwrapped() {
        let message = parse(#"""
        {"type":"response.event","delegation_id":"item_1","event":{"type":"response.output_item.done",
         "item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"One session is open."}]}}}
        """#)
        #expect(message == .backendMessage(delegationID: "item_1", text: "One session is open."))
        let done = parse(#"{"type":"response.event","delegation_id":"item_1","event":{"type":"response.completed","response":{"id":"resp_1"}}}"#)
        #expect(done == .backendCompleted(delegationID: "item_1", responseID: "resp_1"))
    }

    @Test func usageClosedAndErrorsAreRead() {
        #expect(parse(#"{"type":"session.usage.updated","usage":{"seconds":14},"context_window":{"usage_ratio":0.01}}"#)
            == .usage(seconds: 14, contextRatio: 0.01))
        #expect(parse(#"{"type":"session.closed","reason":"expired","usage":{"seconds":7200}}"#)
            == .closed(reason: "expired", seconds: 7200))
        #expect(parse(#"{"type":"error","error":{"code":"tool_outputs_required","message":"Return results first.","client_event_id":"x"}}"#)
            == .error(code: "tool_outputs_required", message: "Return results first.", clientEventID: "x"))
    }

    @Test func audioIsDecodedAndUnknownTypesKeepTheirName() {
        let pcm = Data([1, 0, 2, 0])
        #expect(parse(#"{"type":"session.output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#) == .outputAudio(pcm))
        #expect(parse(#"{"type":"session.something.new"}"#) == .other("session.something.new"))
        #expect(parse(#"{"delta":"x"}"#) == nil)
    }
}

// MARK: - Transcript

@Suite
struct VoiceLedgerTests {
    @Test func fragmentsBecomeTurnsWhenFlushed() {
        var ledger = VoiceLedger()
        ledger.input(" what is")
        ledger.input(" session four doing?")
        ledger.output(" On")
        ledger.output(" it.")
        #expect(ledger.flushUser() == "what is session four doing?")
        #expect(ledger.flushUser() == "")
        #expect(ledger.flushAssistant() == "On it.")
    }

    @Test func billedSecondsOnlyGrow() {
        var ledger = VoiceLedger()
        ledger.usage(seconds: 30)
        ledger.usage(seconds: 12)
        ledger.usage(seconds: .nan)
        #expect(ledger.billedSeconds == 30)
    }

    @Test func markdownIsMadeSayable() {
        let text = VoiceSpeech.speakable("## Done\n- Ran `zig build` in **session 4**\n```swift\nlet x = 1\n```\nSee [the docs](https://x.y).")
        #expect(text == "Done\nRan zig build in session 4\n(there is code here)\nSee the docs.")
    }

    @Test func longAnswersAreCutAtSentencesAndCapped() {
        let sentence = String(repeating: "a", count: 300) + ". "
        let chunks = VoiceSpeech.chunks(String(repeating: sentence, count: 20))
        #expect(chunks.count == VoiceSpeech.maxAppends)
        #expect(chunks.allSatisfy { $0.count <= VoiceSpeech.appendCharacters + VoiceSpeech.truncatedNote.count + 1 })
        #expect(chunks[0].hasSuffix("."))
        #expect(chunks.last?.hasSuffix(VoiceSpeech.truncatedNote) == true)
        #expect(VoiceSpeech.chunks("short") == ["short"])
    }

    @Test func theLogKeepsSpokenTurnsByDay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-log-\(UUID().uuidString)")
        let log = VoiceTranscriptLog(directory: directory)
        let now = Date()
        log.append(VoiceTurn(role: .user, text: "hello", at: now.addingTimeInterval(-10)))
        log.append(VoiceTurn(role: .tool, text: "list_sessions", at: now.addingTimeInterval(-9)))
        log.append(VoiceTurn(role: .assistant, text: "hi", at: now.addingTimeInterval(-8)))
        let recent = log.recent(limit: 10, now: now)
        #expect(recent.map(\.text) == ["hello", "hi"])
        #expect(log.recent(limit: 1, now: now).map(\.text) == ["hi"])
        try FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Memory

@Suite
@MainActor
struct VoiceMemoryTests {
    @Test func notesAreKeptAndRenderedByKind() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-memory-\(UUID().uuidString)/memory.json")
        let store = VoiceMemoryStore(file: file)
        let alias = store.remember(.alias, "\"the board\" means ~/projects/board")
        store.remember(.preference, "Open sessions in a worktree")
        store.remember(.preference, "open sessions in a worktree")
        store.recordFolderUse("/Users/x/projects/board")
        store.recordFolderUse("/Users/x/projects/board")
        store.recordFolderUse("/Users/x/projects/app")
        #expect(store.state.notes.count == 2)

        // Dates come back at second precision, so the notes are compared by what matters.
        let again = VoiceMemoryStore(file: file)
        #expect(again.state.notes.map(\.id) == store.state.notes.map(\.id))
        #expect(again.state.notes.map(\.text) == store.state.notes.map(\.text))
        #expect(again.state.folderUse == store.state.folderUse)
        let prompt = again.prompt()
        #expect(prompt.contains("Terms the user uses:\n- [\(alias.id)] \"the board\" means ~/projects/board"))
        #expect(prompt.contains("Preferences:"))
        #expect(prompt.range(of: "projects/board (2)")! .lowerBound < prompt.range(of: "projects/app (1)")!.lowerBound)

        #expect(again.forget(id: alias.id))
        #expect(!again.forget(id: alias.id))
        #expect(VoiceMemoryStore(file: file).state.notes.count == 1)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func anEmptyMemorySaysSo() {
        #expect(VoiceMemoryStore.prompt(for: VoiceMemoryState(), notes: []).hasPrefix("Nothing yet."))
    }
}

// MARK: - Session references

@Suite
struct VoiceSessionReferenceTests {
    private func candidate(_ number: Int, _ title: String, folder: String? = nil, branch: String? = nil, selected: Bool = false) -> VoiceSessionReference.Candidate {
        VoiceSessionReference.Candidate(
            number: number,
            session: SidebarSession(id: "id-\(number)", title: title, branch: branch, isSelected: selected),
            folder: folder)
    }

    private var candidates: [VoiceSessionReference.Candidate] {
        [
            candidate(1, "Fix login page", folder: "maggie"),
            candidate(2, "Mobile companion", folder: "maggie-pro", branch: "feature/pairing", selected: true),
            candidate(4, "Login tests", folder: "maggie"),
            candidate(8, "Docs", folder: "board"),
        ]
    }

    @Test func numbersInEveryForm() {
        for text in ["4", "#4", "session 4", "Session four", "number four", "tab 4"] {
            #expect(VoiceSessionReference.resolve(text, among: candidates)?.number == 4, "\(text)")
        }
        #expect(VoiceSessionReference.resolve("9", among: candidates) == nil)
    }

    @Test func wordsPickTheOneTitleTheyFit() {
        #expect(VoiceSessionReference.resolve("the mobile one", among: candidates)?.number == 2)
        #expect(VoiceSessionReference.resolve("docs", among: candidates)?.number == 8)
        #expect(VoiceSessionReference.resolve("pairing", among: candidates)?.number == 2)
        #expect(VoiceSessionReference.resolve("login tests", among: candidates)?.number == 4)
        // Two sessions mention login equally: nobody's guess to make.
        #expect(VoiceSessionReference.resolve("login", among: candidates) == nil)
        #expect(VoiceSessionReference.resolve("the board session", among: candidates)?.number == 8)
    }

    @Test func thisMeansTheSelectedSession() {
        #expect(VoiceSessionReference.resolve("this", among: candidates)?.number == 2)
        #expect(VoiceSessionReference.resolve("the current session", among: candidates)?.number == 2)
        #expect(VoiceSessionReference.resolve("", among: candidates) == nil)
    }
}

// MARK: - Watching

@Suite
struct VoiceWatchRulesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func waitingAndFinishingAreNews() {
        var rules = VoiceWatchRules()
        #expect(rules.notice(from: .working, to: .waiting, session: "a", at: now)?.kind == .needsYou)
        #expect(rules.notice(from: .working, to: .clean, session: "b", at: now)?.kind == .finished)
        #expect(rules.notice(from: .working, to: .pending, session: "c", at: now)?.kind == .finished)
        #expect(rules.notice(from: .clean, to: .waiting, session: "d", at: now)?.kind == .needsYou)
        #expect(rules.notice(from: .waiting, to: .working, session: "e", at: now) == nil)
        #expect(rules.notice(from: nil, to: .waiting, session: "f", at: now) == nil)
        #expect(rules.notice(from: .pending, to: .clean, session: "g", at: now) == nil)
    }

    @Test func oneNoticeASessionEveryHalfMinute() {
        var rules = VoiceWatchRules()
        #expect(rules.notice(from: .working, to: .waiting, session: "a", at: now) != nil)
        #expect(rules.notice(from: .working, to: .clean, session: "a", at: now.addingTimeInterval(10)) == nil)
        #expect(rules.notice(from: .working, to: .clean, session: "a", at: now.addingTimeInterval(31)) != nil)
    }

    @Test func onlyWatchedSessionsAreAnnouncedUnlessAllAre() {
        var rules = VoiceWatchRules()
        let before = SidebarSnapshot(rows: [
            .session(SidebarSession(id: "a", title: "A", light: .working)),
            .session(SidebarSession(id: "b", title: "B", light: .working)),
        ])
        let after = SidebarSnapshot(rows: [
            .session(SidebarSession(id: "a", title: "A", light: .clean)),
            .session(SidebarSession(id: "b", title: "B", light: .waiting)),
            .session(SidebarSession(id: "c", title: "C", light: .waiting)),
        ])
        let some = rules.notices(from: before, to: after, watched: ["a"], all: false, at: now)
        #expect(some == [VoiceWatchRules.Notice(sessionID: "a", kind: .finished)])
        var everyone = VoiceWatchRules()
        let all = everyone.notices(from: before, to: after, watched: [], all: true, at: now)
        #expect(all.map(\.sessionID) == ["a", "b"])
    }
}

// MARK: - Tools and prompts

@Suite
@MainActor
struct VoiceToolsTests {
    @Test func spokenKeyNamesMapToKeys() {
        #expect(VoiceTools.key(named: "Enter")?.0 == .enter)
        #expect(VoiceTools.key(named: "esc")?.0 == .escape)
        #expect(VoiceTools.key(named: "down")?.0 == .arrowDown)
        #expect(VoiceTools.key(named: "3")?.0 == .digit3)
        #expect(VoiceTools.key(named: "yes")?.0 == .y)
        let control = VoiceTools.key(named: "ctrl-c")
        #expect(control?.0 == .c)
        #expect(control?.1 == [.ctrl])
        #expect(VoiceTools.key(named: "f13") == nil)
    }

    @Test func sidebarFoldersAreFoundByNameOrPath() {
        let snapshot = SidebarSnapshot(rows: [
            .folder(SidebarFolder(id: "1", name: "Maggie", path: "/Users/x/projects/maggie", abbreviatedPath: "~/projects/maggie", hasGit: true, rows: [])),
            .folder(SidebarFolder(id: "2", name: "Maggie Pro", path: "/Users/x/projects/maggie-pro", abbreviatedPath: "~/projects/maggie-pro", hasGit: true, rows: [])),
        ])
        #expect(VoiceTools.sidebarFolder(named: "maggie", in: snapshot)?.id == "1")
        #expect(VoiceTools.sidebarFolder(named: "~/projects/maggie-pro", in: snapshot)?.id == "2")
        #expect(VoiceTools.sidebarFolder(named: "pro", in: snapshot)?.id == "2")
        #expect(VoiceTools.sidebarFolder(named: "mag", in: snapshot) == nil)
    }

    @Test func everyToolHasAnObjectSchemaAndIsNamedToTheVoice() {
        for definition in VoiceTools.definitions {
            #expect(definition.parameters["type"] as? String == "object", Comment(rawValue: definition.name))
            #expect(JSONSerialization.isValidJSONObject(definition.json), Comment(rawValue: definition.name))
        }
        let live = VoicePrompt.liveInstructions(capabilities: VoiceTools.capabilities, userName: "Marcio")
        for heading in ["Backchannel policy:", "Interruption policy:", "Delegation policy:", "Backend tools:", "Delegate to the backend when:", "Do not delegate to the backend when:"] {
            #expect(live.contains(heading), Comment(rawValue: heading))
        }
        #expect(live.contains("- tell_session: Types an instruction into a session's agent and submits it, as the user would."))
        #expect(live.contains("The user's name is Marcio."))
        #expect(live.utf8.count < 42_000)
    }

    @Test func theBackendHearsMemoryAndSessions() {
        let text = VoicePrompt.backendInstructions(memory: "Facts:\n- [ab12] likes worktrees", sessionsNow: "- 1: Login, working")
        #expect(text.contains("# What you know about this user\nFacts:\n- [ab12] likes worktrees"))
        #expect(text.contains("# Sessions right now\n- 1: Login, working"))
        #expect(VoicePrompt.notice("Session 4 finished.") == "[Maggie notice] Session 4 finished.")
    }
}

// MARK: - Audio

@Suite
struct VoiceAudioFormatTests {
    @Test func floatsBecomeLittleEndianPCM16() {
        let data = VoiceAudioFormat.pcm16(from: [0, 1, -1, 0.5, 2, -2])
        let samples = data.withUnsafeBytes { raw in
            (0..<6).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        #expect(samples == [0, 0x7FFF, -0x8000, 0x3FFF, 0x7FFF, -0x8000])
        #expect(VoiceAudioFormat.chunkBytes == 4800)
    }
}

// MARK: - Previews

@Suite
struct VoicePreviewTests {
    @Test func aVoiceIntroducesItself() {
        #expect(VoicePreview.sample(for: "marin") == "Hi, I'm Marin, this is how I sound.")
        #expect(VoicePreview.sample(for: "quartz") == "Hi, I'm Quartz, this is how I sound.")
        #expect(VoicePreview.instructions(for: "marin").contains("word for word"))
    }

    @Test func theLineIsAskedForOnceAndIsOverWhenTheSpeechGoesQuiet() {
        var collector = VoicePreviewCollector()
        #expect(collector.take(.other("session.updated")) == .nothing)
        #expect(collector.take(.started(sessionID: "s", expiresAt: nil)) == .ask)
        #expect(collector.take(.started(sessionID: "s", expiresAt: nil)) == .nothing)
        #expect(collector.take(.outputTranscript("Hi")) == .nothing)
        // A tenth of a second of quiet, and of speech.
        let quiet = Data(count: 4800)
        let loud = Data(repeating: 0x10, count: 4800)
        #expect(!VoicePreviewCollector.isLoud(quiet) && VoicePreviewCollector.isLoud(loud))
        for _ in 0..<3 { #expect(collector.take(.outputAudio(quiet)) == .heard) }
        for _ in 0..<5 { #expect(collector.take(.outputAudio(loud)) == .heard) }
        for _ in 0..<7 { #expect(collector.take(.outputAudio(quiet)) == .heard) }
        // The eighth quiet tenth makes 0.8 s: the line is over, kept with 0.2 s either side.
        let step = collector.take(.outputAudio(quiet))
        guard case .done(let sample) = step else {
            Issue.record("expected the sample, got \(step)")
            return
        }
        #expect(sample.count == (2 + 5 + 2) * 4800)
        #expect(sample == Data(count: 2 * 4800) + loud + loud + loud + loud + loud + Data(count: 2 * 4800))
        #expect(collector.take(.closed(reason: "client_closed", seconds: 2)) == .nothing)
    }

    @Test func aStreamThatStopsShortGivesWhatWasHeard() {
        var collector = VoicePreviewCollector()
        _ = collector.take(.started(sessionID: "s", expiresAt: nil))
        let loud = Data(repeating: 0x10, count: 4800)
        _ = collector.take(.outputAudio(loud))
        _ = collector.take(.outputAudio(Data(count: 4800)))
        #expect(collector.sample.count == 2 * 4800)
        #expect(collector.sample.prefix(4800) == loud)
        // Nothing loud yet: everything so far.
        var silent = VoicePreviewCollector()
        _ = silent.take(.outputAudio(Data(count: 100)))
        #expect(silent.sample.count == 100)
    }

    @Test func aSessionThatFailsOrClosesSilentIsAFailure() {
        var collector = VoicePreviewCollector()
        #expect(collector.take(.error(code: "invalid_value", message: "bad voice", clientEventID: nil)) == .failed("bad voice"))
        #expect(collector.take(.closed(reason: "server_error", seconds: nil)) == .failed("GPT-Live closed the session: server_error"))
    }

    @MainActor
    @Test func samplesAreKeptPerVoiceApartFromOtherFiles() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-previews-\(UUID().uuidString)")
        let preview = VoicePreview(directory: directory)
        #expect(preview.file(for: "marin").lastPathComponent == "marin.pcm")
        #expect(preview.file(for: "marin").path.hasPrefix(directory.path + "/"))
        #expect(preview.phase == .idle)
    }

    /// Fetches a real sample and plays it; run with TEST_RUNNER_VOICE_PREVIEW_LIVE=1.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICE_PREVIEW_LIVE"] == "1"))
    func aRealVoiceSaysItsLine() async throws {
        let apiKey = try #require(OpenAI.apiKey())
        let voice = ProcessInfo.processInfo.environment["VOICE_PREVIEW_VOICE"] ?? "quartz"
        let fetch = VoicePreviewFetch(apiKey: apiKey, voice: voice, line: VoicePreview.sample(for: voice), instructions: VoicePreview.instructions(for: voice))
        let pcm: Data = try await withCheckedThrowingContinuation { continuation in
            fetch.start { continuation.resume(with: $0) }
        }
        let seconds = Double(pcm.count) / 2 / Double(VoiceAudioFormat.sampleRate)
        print("sample for \(voice): \(pcm.count) bytes, \(seconds) s")
        try pcm.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("voice-preview-\(voice).pcm"))
        #expect(seconds > 1 && seconds < 15)
        let player = VoicePreviewPlayer()
        let played: Bool = try await withCheckedThrowingContinuation { continuation in
            do {
                try player.play(pcm, outputDevice: nil) { continuation.resume(returning: true) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(played)
    }
}

// MARK: - Devices

@Suite
struct VoiceDevicesTests {
    @Test func theMacsDevicesAreListedWithNames() {
        let devices = VoiceDevices.all()
        #expect(devices.allSatisfy { !$0.name.isEmpty && !$0.uid.isEmpty && ($0.hasInput || $0.hasOutput) })
        if let output = VoiceDevices.defaultDevice(input: false) {
            #expect(devices.contains { $0.id == output })
        }
        #expect(VoiceDevices.device(uid: "") == nil)
        #expect(VoiceDevices.device(uid: "no-such-device") == nil)
    }
}

// MARK: - Wake phrases

@Suite
struct VoiceWakeTests {
    @Test func wakePhrasesAreHeardThroughPunctuationAndCase() {
        #expect(VoiceWakeListener.matches("Hey, Maggie!") == "hey maggie")
        #expect(VoiceWakeListener.matches("could you un-mute please") == "un mute")
        #expect(VoiceWakeListener.matches("UNMUTE") == "unmute")
        #expect(VoiceWakeListener.matches("the magpie flew") == nil)
        #expect(VoiceWakeListener.matches("") == nil)
    }
}

@Suite
struct VoiceWakeRecognitionTests {
    /// "Hey Maggie, unmute", spoken by `say` and fed in tenth-of-a-second buffers the way
    /// the voice's engine feeds a muted microphone. On 2026-10-18 the old recogniser
    /// failed every request with error 201 on a Mac with Dictation off; this is heard.
    /// SpeechAnalyzer hears nothing in an app without the speech permission, which a test
    /// can't grant, so this runs where the test host has been allowed it.
    @available(macOS 26.0, *)
    @Test(
        .timeLimit(.minutes(1)),
        .enabled(if: SFSpeechRecognizer.authorizationStatus() == .authorized, "needs the speech recognition permission"))
    func spokenUnmuteIsHeardWithoutDictation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("unmute.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "Hey Maggie. Unmute."]
        try say.run()
        say.waitUntilExit()
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate / 10)

        let recognizer = AnalyzerWakeRecognizer()
        let heard = HeardText()
        recognizer.onText = { heard.add($0) }
        recognizer.onFailure = { heard.add("failure: \($0)") }
        recognizer.begin()
        defer { recognizer.end() }
        for _ in 0..<200 where !recognizer.isReady {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(recognizer.isReady)

        // A second of silence after the words lets the transcriber finish them.
        while audio.framePosition < audio.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            try audio.read(into: buffer, frameCount: frames)
            recognizer.append(buffer)
        }
        for _ in 0..<10 {
            let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            silence.frameLength = frames
            recognizer.append(silence)
        }
        for _ in 0..<300 where VoiceWakeListener.matches(heard.text) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(VoiceWakeListener.matches(heard.text) != nil, Comment(rawValue: "heard: \(heard.text)"))
    }

    @Test func theOldRecognizerBacksOffInsteadOfSpinning() {
        #expect(LegacyWakeRecognizer.retryDelay(afterFailures: 0) == 0)
        #expect(LegacyWakeRecognizer.retryDelay(afterFailures: 1) == 0.5)
        #expect(LegacyWakeRecognizer.retryDelay(afterFailures: 3) == 2)
        #expect(LegacyWakeRecognizer.retryDelay(afterFailures: 20) == 30)
    }

    private final class HeardText: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ text: String) { lock.lock(); all.append(text); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return all.joined(separator: " | ") }
    }
}

// MARK: - Mute and unmute by voice

@Suite
struct VoiceCommandTests {
    /// What the user said on 2026-10-16 when asking to mute; GPT-Live answered "muting
    /// now" to the first three without muting.
    @Test func politeRequestsToMuteMute() {
        for text in [
            "Yeah. Can you mute yourself, please",
            "Mute yourself, please",
            "Can you mute yourself",
            "mute",
            "Mute.",
            "Maggie, mute the microphone",
            "Could you please mute for a second?",
            "okay, stop listening",
            "Can you mute yourself?",
            // 2026-10-17: missed by the first parser; the backend's tool caught it.
            "That’s okay. Can you please mute yourself",
        ] {
            #expect(VoiceCommand.parse(text) == .mute, Comment(rawValue: text))
        }
    }

    @Test func talkAboutMutingIsNotACommand() {
        for text in [
            "It doesn't seem that it is muted",
            "Still not muted",
            "the mute didn't work",
            "Yeah, okay. It took like you a few tries uh, to be able to mute, and then finally worked, but the unmute didn't work",
            "can you mute session four",
            "Mute. Then tell session four to stop",
            "Can you hear",
            ", un",
            "",
            "please",
        ] {
            #expect(VoiceCommand.parse(text) == nil, Comment(rawValue: text))
        }
    }

    @Test func unmuteIsHeardInItsForms() {
        #expect(VoiceCommand.parse("Unmute") == .unmute)
        #expect(VoiceCommand.parse("un-mute yourself please") == .unmute)
        #expect(VoiceCommand.parse("Hey Maggie, unmute") == .unmute)
        #expect(VoiceCommand.parse("unmute the mic") == .unmute)
    }
}

@Suite
@MainActor
struct VoiceWakeSourceTests {
    @Test func mutedListensToTheVoicesOwnMicrophone() {
        // Under voice processing a second engine on the microphone hears silence, so
        // muted, the listener is fed by the voice's engine, on the Mac or a handset.
        #expect(VoiceAgent.wakeSource(phase: .live, muted: true, local: true) == .fed)
        #expect(VoiceAgent.wakeSource(phase: .live, muted: true, local: false) == .fed)
    }

    @Test func pausedOpensTheMacsMicrophone() {
        #expect(VoiceAgent.wakeSource(phase: .paused, muted: false, local: true) == .microphone)
        #expect(VoiceAgent.wakeSource(phase: .paused, muted: true, local: true) == .microphone)
        #expect(VoiceAgent.wakeSource(phase: .paused, muted: false, local: false) == nil)
    }

    @Test func listeningOrOffNeedsNoWakeListener() {
        #expect(VoiceAgent.wakeSource(phase: .live, muted: false, local: true) == nil)
        #expect(VoiceAgent.wakeSource(phase: .connecting, muted: true, local: true) == nil)
        #expect(VoiceAgent.wakeSource(phase: .off, muted: true, local: true) == nil)
        #expect(VoiceAgent.wakeSource(phase: .failed("x"), muted: true, local: true) == nil)
    }

    @Test func theUserIsHeardOverTheVoice() {
        // Muted mid-reply, "hey Maggie" said over the voice wakes it (v0.22 dropped it).
        #expect(!VoiceAgent.isEcho("hey maggie", assistantSaid: "Session four finished its build and the tests pass."))
        #expect(!VoiceAgent.isEcho("unmute", assistantSaid: " "))
    }

    @Test func theVoicesOwnWordsDontWakeIt() {
        #expect(VoiceAgent.isEcho("unmute", assistantSaid: "Say unmute when you want me back."))
        #expect(VoiceAgent.isEcho("hey maggie", assistantSaid: "You can say \"Hey, Maggie\" any time."))
    }
}
