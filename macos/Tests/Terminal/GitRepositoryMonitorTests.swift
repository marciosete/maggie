import Combine
import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
struct GitRepositoryMonitorTests {
    // MARK: Running git

    /// A process git starts, such as a hook's background job, can keep git's output
    /// open long after git exits. That must not hold up the read.
    @Test func aLingeringChildDoesNotHoldUpTheOutput() {
        let started = Date()
        let result = Git.execute(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(sleep 20 &); echo done"],
            in: FileManager.default.temporaryDirectory,
            timeout: 10)
        #expect(result.succeeded)
        #expect(result.output == "done\n")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aStuckProgramIsGivenUpOn() {
        let started = Date()
        let result = Git.execute(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 20"],
            in: FileManager.default.temporaryDirectory,
            timeout: 1)
        #expect(!result.succeeded)
        #expect(result.message == "sh took more than 1s and was stopped")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aFailureIsExplained() {
        let silent = Git.execute(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"],
            in: FileManager.default.temporaryDirectory, timeout: 10)
        #expect(!silent.succeeded)
        #expect(silent.message == "sh exited with status 3")

        let spoken = Git.execute(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo oops >&2; exit 1"],
            in: FileManager.default.temporaryDirectory, timeout: 10)
        #expect(!spoken.succeeded)
        #expect(spoken.message == "oops")
    }

    @Test func statusSaysWhyItFailed() throws {
        let root = try Self.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try #require(Git.repository(containing: root))

        #expect(Git.status(of: repository) != nil)

        try Self.corruptIndex(of: repository)
        switch Git.readStatus(of: repository) {
        case .success: Issue.record("The status was read from a corrupt index")
        case .failure(let failure): #expect(failure.message.contains("index"))
        }
        #expect(Git.status(of: repository) == nil)
    }

    // MARK: Monitoring

    /// A `git status` that fails is reported, and tried again until it works.
    @Test func aFailedStatusIsReportedAndRetried() async throws {
        let root = try Self.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try #require(Git.repository(containing: root))
        try Self.corruptIndex(of: repository)

        let monitor = await MainActor.run { GitRepositoryMonitor.monitor(for: repository) }
        try await Self.wait { monitor.failure != nil }
        #expect(monitor.status == nil)

        // Nothing changes, so only a retry can run another status, which fails too.
        try await Task.sleep(nanoseconds: UInt64(GitRepositoryMonitor.retryDelays[0] * 1_500_000_000))
        #expect(monitor.status == nil)
        #expect(monitor.failure != nil)

        try FileManager.default.removeItem(at: repository.gitDir.appendingPathComponent("index"))
        try await Self.wait { monitor.status != nil }
        #expect(monitor.failure == nil)
    }

    /// The panel says why the repository can't be read instead of waiting for a status
    /// that never comes, and shows the status once it can be read.
    @Test @MainActor func thePanelSaysWhyTheRepositoryCannotBeRead() async throws {
        let root = try Self.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try #require(Git.repository(containing: root))
        try Self.corruptIndex(of: repository)

        let model = SourceControlPanelModel()
        model.setVisible(true)
        model.setDirectory(root.path)
        try await Self.wait {
            if case .unavailable(let shown, let reason) = model.state {
                #expect(shown == repository)
                #expect(reason.contains("index"))
                return true
            }
            return false
        }

        try FileManager.default.removeItem(at: repository.gitDir.appendingPathComponent("index"))
        try await Self.wait { model.state.isReady }
        model.setVisible(false)
    }

    // MARK: Helpers

    /// An empty repository with one committed file.
    private static func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try git(["config", "user.name", "Test"], in: root)
        try git(["config", "user.email", "test@example.com"], in: root)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try git(["add", "file.txt"], in: root)
        try git(["commit", "-q", "-m", "First"], in: root)
        return root
    }

    /// Leaves the index unreadable, which `git status` needs and `git rev-parse` doesn't.
    private static func corruptIndex(of repository: Git.Repository) throws {
        try Data("not an index".utf8).write(to: repository.gitDir.appendingPathComponent("index"))
    }

    /// Waits up to ten seconds for `condition`.
    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out")
        throw CancellationError()
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = Git.executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
