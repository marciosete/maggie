import Darwin
import Foundation
import Testing
@testable import Ghostty

struct StatusBarTests {
    // MARK: Formatting

    @Test func resetTimesReadLikeOrcas() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(StatusBarFormat.reset(now.addingTimeInterval(47 * 60 + 30), at: now) == "47m")
        #expect(StatusBarFormat.reset(now.addingTimeInterval((3 * 60 + 54) * 60), at: now) == "3h 54m")
        #expect(StatusBarFormat.reset(now.addingTimeInterval(((6 * 24) + 7) * 3600 + 120), at: now) == "6d 7h")
        #expect(StatusBarFormat.reset(now.addingTimeInterval(-60), at: now) == "0m")
    }

    @Test func memoryAndCPUFormats() {
        #expect(ResourceFormat.memory(512 * 1024) == "512 KB")
        #expect(ResourceFormat.memory(UInt64(612.0 * 1_048_576)) == "612.0 MB")
        #expect(ResourceFormat.memory(UInt64(1.5 * 1_073_741_824)) == "1.50 GB")
        #expect(ResourceFormat.cpu(3.24) == "3.2%")
        #expect(ResourceFormat.cpu(142.6) == "143%")
    }

    // MARK: Process trees

    @Test func aTerminalsRootIsTheAppsChildAboveItsForegroundProcess() {
        // app 100 → login 200 → zsh 300 → claude 400
        let parents: [pid_t: pid_t] = [200: 100, 300: 200, 400: 300, 100: 1, 500: 1]
        #expect(ResourceSampler.root(of: 400, under: 100, parents: parents) == 200)
        #expect(ResourceSampler.root(of: 200, under: 100, parents: parents) == 200)
        #expect(ResourceSampler.root(of: 500, under: 100, parents: parents) == nil)
    }

    @Test func aTreeHoldsEveryDescendantOnce() {
        let children: [pid_t: [pid_t]] = [200: [300, 301], 300: [400], 400: [200]]
        #expect(Set(ResourceSampler.tree(from: 200, children: children)) == [200, 300, 301, 400])
    }

    @Test func theProcessTableHasThisProcess() {
        let parents = ResourceSampler.parents()
        #expect(parents[getpid()] == getppid())
    }

    @Test func aSampleMeasuresTheAppAndItsSessions() throws {
        // A child of the test host stands in for a terminal's process.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }

        let sampler = ResourceSampler()
        let id = ObjectIdentifier(sampler)
        let first = sampler.sample([.init(id: id, pids: [child.processIdentifier])])
        let session = try #require(first.sessions[id])
        #expect(session.processCount == 1)
        #expect(session.usage.memory > 0)
        #expect(first.app.memory > session.usage.memory)

        // The second sample can tell how busy each was in between.
        let second = sampler.sample([.init(id: id, pids: [child.processIdentifier])])
        #expect(second.app.cpu >= 0)
    }
}
