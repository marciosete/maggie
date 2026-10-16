import Foundation
import Testing
@testable import MaggieRemote

struct RemoteFrameTests {
    @Test(arguments: [RemoteFrame.Kind.output, .input, .resize, .snapshot, .voiceInput, .voiceOutput])
    func frameRoundTrips(_ kind: RemoteFrame.Kind) throws {
        let frame = RemoteFrame(stream: 0xDEAD_BEEF, kind: kind, payload: Data("hello\u{1b}[31m".utf8))
        #expect(try RemoteFrame(decoding: frame.encoded()) == frame)
    }

    @Test func headerIsBigEndian() {
        let data = RemoteFrame(stream: 0x0102_0304, kind: .output, payload: Data([0xFF])).encoded()
        #expect(Array(data) == [1, 2, 3, 4, 1, 0xFF])
    }

    @Test func emptyPayloadRoundTrips() throws {
        let frame = RemoteFrame(stream: 1, kind: .input, payload: Data())
        #expect(try RemoteFrame(decoding: frame.encoded()) == frame)
    }

    @Test func resizeCarriesTheGrid() throws {
        let frame = RemoteFrame.resize(stream: 3, columns: 213, rows: 61)
        let decoded = try RemoteFrame(decoding: frame.encoded())
        #expect(decoded.kind == .resize)
        #expect(decoded.size?.columns == 213)
        #expect(decoded.size?.rows == 61)
    }

    @Test func snapshotCarriesTheGridAndTheScreen() throws {
        let vt = Data("\u{1b}c\u{1b}[1mhi".utf8)
        let decoded = try RemoteFrame(decoding: RemoteFrame.snapshot(stream: 4, columns: 132, rows: 43, vt: vt).encoded())
        #expect(decoded.kind == .snapshot)
        #expect(decoded.snapshot?.columns == 132)
        #expect(decoded.snapshot?.rows == 43)
        #expect(decoded.snapshot?.vt == vt)
        #expect(RemoteFrame(stream: 4, kind: .snapshot, payload: Data([0])).snapshot == nil)
    }

    @Test func decodesFromASliceThatDoesNotStartAtZero() throws {
        let frame = RemoteFrame(stream: 9, kind: .output, payload: Data("x".utf8))
        let padded = Data([0, 0]) + frame.encoded()
        #expect(try RemoteFrame(decoding: padded.dropFirst(2)) == frame)
    }

    @Test func rejectsShortAndUnknownFrames() {
        #expect(throws: RemoteFrame.DecodeError.tooShort) { try RemoteFrame(decoding: Data([0, 0, 0])) }
        #expect(throws: RemoteFrame.DecodeError.unknownKind(99)) { try RemoteFrame(decoding: Data([0, 0, 0, 1, 99])) }
    }
}
