import CryptoKit
import Foundation

/// What the Mac's pairing QR code carries:
/// `maggie://pair?host=…&port=…&fp=…&code=…&name=…`.
///
/// `fp` is the SHA-256 of the Mac's TLS certificate, which the device pins from then on;
/// `code` is the one-time pairing code, valid for a few minutes.
public struct PairingInvitation: Equatable, Sendable {
    public static let scheme = "maggie"
    public static let action = "pair"

    /// How long a pairing code is accepted after the Mac shows it.
    public static let codeLifetime: TimeInterval = 5 * 60

    /// A host name or address the device can reach the Mac at, such as its Tailscale name.
    public var host: String
    public var port: UInt16
    public var fingerprint: CertificateFingerprint
    public var code: String

    /// The Mac's name, for the device's list of hosts.
    public var name: String?

    public init(host: String, port: UInt16, fingerprint: CertificateFingerprint, code: String, name: String? = nil) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.code = code
        self.name = name
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.action
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fp", value: fingerprint.hex),
            URLQueryItem(name: "code", value: code),
        ] + (name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        return components.url!
    }

    /// Reads a scanned or pasted invitation; nil if it isn't one.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme,
              components.host == Self.action else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { values[item.name] = value }
        }
        guard let host = values["host"], !host.isEmpty,
              let port = values["port"].flatMap(UInt16.init),
              let fingerprint = values["fp"].flatMap(CertificateFingerprint.init(hex:)),
              let code = values["code"], !code.isEmpty else { return nil }
        self.init(host: host, port: port, fingerprint: fingerprint, code: code, name: values["name"])
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }
}

/// The SHA-256 of a DER-encoded certificate.
public struct CertificateFingerprint: Hashable, Codable, Sendable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == SHA256.byteCount else { return nil }
        self.bytes = bytes
    }

    public init(certificate der: Data) {
        bytes = Data(SHA256.hash(data: der))
    }

    public init?(hex: String) {
        let digits = hex.lowercased().filter { $0 != ":" }
        guard digits.count == SHA256.byteCount * 2 else { return nil }
        var data = Data(capacity: SHA256.byteCount)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self.bytes = data
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Colon-separated pairs in upper case, the way Keychain Access shows fingerprints.
    public var displayString: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(hex: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a SHA-256 fingerprint")
        }
        self = value
    }
}

/// Device tokens: minted by the Mac at pairing, kept only as a hash there.
public enum DeviceToken {
    /// A new random 32-byte token, base64url encoded.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The hash the Mac stores in place of the token.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One-time pairing codes: six digits.
public enum PairingCode {
    public static func generate() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}
