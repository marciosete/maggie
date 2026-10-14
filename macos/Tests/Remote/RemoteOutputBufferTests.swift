import Foundation
import Testing
@testable import Ghostty

@Suite
struct RemoteOutputBufferTests {
    private func bytes(_ count: Int, _ value: UInt8 = 0x41) -> Data {
        Data(repeating: value, count: count)
    }

    @Test func outputRunsMergeIntoOneFrame() {
        var buffer = RemoteOutputBuffer(capacity: 1 << 20)
        #expect(buffer.append(.output(Data("ab".utf8))) == .buffered)
        #expect(buffer.append(.output(Data("cd".utf8))) == .buffered)
        #expect(buffer.drain() == [.output(Data("abcd".utf8))])
        #expect(buffer.drain().isEmpty)
    }

    @Test func resizesKeepTheirPlaceInTheStream() {
        var buffer = RemoteOutputBuffer(capacity: 1 << 20)
        _ = buffer.append(.output(Data("before".utf8)))
        _ = buffer.append(.resize(columns: 80, rows: 24))
        _ = buffer.append(.output(Data("after".utf8)))
        #expect(buffer.drain() == [
            .output(Data("before".utf8)),
            .resize(columns: 80, rows: 24),
            .output(Data("after".utf8)),
        ])
    }

    @Test func enoughOutputFlushesAtOnce() {
        var buffer = RemoteOutputBuffer(capacity: 1 << 20)
        #expect(buffer.append(.output(bytes(RemoteOutputBuffer.flushBytes - 1))) == .buffered)
        #expect(buffer.append(.output(bytes(1))) == .flushNow)
    }

    @Test func aSnapshotReplacesWhatWaits() {
        var buffer = RemoteOutputBuffer(capacity: 1 << 20)
        _ = buffer.append(.output(Data("stale".utf8)))
        #expect(buffer.append(.snapshot(columns: 80, rows: 24, vt: Data("snap".utf8))) == .flushNow)
        _ = buffer.append(.output(Data("fresh".utf8)))
        #expect(buffer.drain() == [.snapshot(columns: 80, rows: 24, vt: Data("snap".utf8)), .output(Data("fresh".utf8))])
    }

    @Test func overflowDropsEverythingUntilTheNextSnapshot() {
        var buffer = RemoteOutputBuffer(capacity: 100)
        #expect(buffer.append(.output(bytes(60))) == .buffered)
        #expect(buffer.append(.output(bytes(60))) == .overflowed)
        #expect(buffer.awaitingSnapshot)
        #expect(buffer.items.isEmpty)

        // Nothing goes out until the snapshot does.
        #expect(buffer.append(.output(bytes(10))) == .buffered)
        #expect(buffer.append(.resize(columns: 1, rows: 1)) == .buffered)
        #expect(buffer.items.isEmpty)

        #expect(buffer.append(.snapshot(columns: 80, rows: 24, vt: Data("snap".utf8))) == .flushNow)
        #expect(!buffer.awaitingSnapshot)
        _ = buffer.append(.output(Data("x".utf8)))
        #expect(buffer.drain() == [.snapshot(columns: 80, rows: 24, vt: Data("snap".utf8)), .output(Data("x".utf8))])
    }

    @Test func aSlowLinkWaitsForASnapshot() {
        var buffer = RemoteOutputBuffer(capacity: 1 << 20)
        _ = buffer.append(.output(Data("backlog".utf8)))
        buffer.dropForSnapshot()
        #expect(buffer.items.isEmpty)
        #expect(buffer.append(.output(Data("more".utf8))) == .buffered)
        #expect(buffer.drain().isEmpty)
    }
}
