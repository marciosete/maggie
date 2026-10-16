import Foundation

/// A binary WebSocket frame: terminal bytes for one mirrored session.
///
/// Layout, big-endian: `[u32 stream][u8 kind][payload]`. The stream number comes from
/// `sessionOpened`.
public struct RemoteFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// Mac to device: bytes the session's pty printed.
        case output = 1

        /// Device to Mac: bytes for the pty, already encoded as the terminal expects.
        case input = 2

        /// Mac to device: the grid was resized. Payload: u16 columns, u16 rows.
        case resize = 3

        /// Mac to device: the whole terminal as VT sequences. Payload: u16 columns, u16
        /// rows, then the sequences. The mirror is rebuilt by writing them into a fresh
        /// terminal of that size; output frames after it apply on top.
        case snapshot = 4

        /// Device to Mac, on `RemoteProtocol.voiceStream`: the handset's microphone, as
        /// `RemoteProtocol.voiceSampleRate` PCM.
        case voiceInput = 5

        /// Mac to device, on `RemoteProtocol.voiceStream`: the voice's speech, as the
        /// same PCM, to play as it arrives.
        case voiceOutput = 6
    }

    public static let headerLength = 5

    public var stream: UInt32
    public var kind: Kind
    public var payload: Data

    public init(stream: UInt32, kind: Kind, payload: Data) {
        self.stream = stream
        self.kind = kind
        self.payload = payload
    }

    public static func resize(stream: UInt32, columns: UInt16, rows: UInt16) -> RemoteFrame {
        var payload = Data(capacity: 4)
        payload.append(bigEndian: columns)
        payload.append(bigEndian: rows)
        return RemoteFrame(stream: stream, kind: .resize, payload: payload)
    }

    public static func snapshot(stream: UInt32, columns: UInt16, rows: UInt16, vt: Data) -> RemoteFrame {
        var payload = Data(capacity: 4 + vt.count)
        payload.append(bigEndian: columns)
        payload.append(bigEndian: rows)
        payload.append(vt)
        return RemoteFrame(stream: stream, kind: .snapshot, payload: payload)
    }

    /// The grid size and VT sequences a snapshot frame carries.
    public var snapshot: (columns: UInt16, rows: UInt16, vt: Data)? {
        guard kind == .snapshot, payload.count >= 4 else { return nil }
        return (payload.readBigEndian(at: 0), payload.readBigEndian(at: 2), Data(payload.dropFirst(4)))
    }

    /// The grid size a resize frame carries.
    public var size: (columns: UInt16, rows: UInt16)? {
        guard kind == .resize, payload.count == 4 else { return nil }
        return (payload.readBigEndian(at: 0), payload.readBigEndian(at: 2))
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        data.append(bigEndian: stream)
        data.append(kind.rawValue)
        data.append(payload)
        return data
    }

    public enum DecodeError: Error, Equatable {
        case tooShort
        case unknownKind(UInt8)
    }

    public init(decoding data: Data) throws {
        guard data.count >= Self.headerLength else { throw DecodeError.tooShort }
        let rawKind = data[data.startIndex + 4]
        guard let kind = Kind(rawValue: rawKind) else { throw DecodeError.unknownKind(rawKind) }
        self.stream = data.readBigEndian(at: 0)
        self.kind = kind
        self.payload = Data(data[(data.startIndex + Self.headerLength)...])
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value = value << 8 | T(self[startIndex + offset + index])
        }
        return value
    }
}
