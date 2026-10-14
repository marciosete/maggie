import Foundation
import Security

/// A self-signed X.509 certificate for a P-256 key, which the Mac serves TLS with. Nobody
/// vouches for it: the device trusts it because its fingerprint came in the pairing QR.
public enum SelfSignedCertificate {
    public enum Failure: Error {
        case publicKey
        case signature(String)
    }

    /// DER for a certificate naming `commonName`, valid from a day ago for `years`,
    /// signed by `privateKey` (an EC P-256 key).
    public static func make(privateKey: SecKey, commonName: String, years: Int = 20, now: Date = Date()) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw Failure.publicKey }

        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid(OID.commonName), DER.utf8String(commonName)])]),
        ])
        let notBefore = now.addingTimeInterval(-24 * 60 * 60)
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: years, to: now) ?? now
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F // Positive.

        let algorithm = DER.sequence([DER.oid(OID.ecdsaWithSHA256)])
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer([2])), // v3
            DER.integer(serial),
            algorithm,
            name,
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name,
            DER.sequence([
                DER.sequence([DER.oid(OID.ecPublicKey), DER.oid(OID.prime256v1)]),
                DER.bitString(point),
            ]),
        ])

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw Failure.signature(error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
        }
        return DER.sequence([tbs, algorithm, DER.bitString(signature)])
    }

    private enum OID {
        static let commonName = [2, 5, 4, 3]
        static let ecdsaWithSHA256 = [1, 2, 840, 10045, 4, 3, 2]
        static let ecPublicKey = [1, 2, 840, 10045, 2, 1]
        static let prime256v1 = [1, 2, 840, 10045, 3, 1, 7]
    }

    /// Just enough DER to write a certificate.
    enum DER {
        static func sequence(_ items: [Data]) -> Data { element(0x30, items.reduce(Data(), +)) }
        static func set(_ items: [Data]) -> Data { element(0x31, items.reduce(Data(), +)) }
        static func explicit(_ tag: UInt8, _ content: Data) -> Data { element(0xA0 | tag, content) }
        static func utf8String(_ string: String) -> Data { element(0x0C, Data(string.utf8)) }
        static func bitString(_ bytes: Data) -> Data { element(0x03, Data([0]) + bytes) }

        static func integer(_ bytes: [UInt8]) -> Data {
            var bytes = Array(bytes.drop { $0 == 0 })
            if bytes.isEmpty { bytes = [0] }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return element(0x02, Data(bytes))
        }

        static func oid(_ arcs: [Int]) -> Data {
            var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
            for arc in arcs.dropFirst(2) {
                var chunk = [UInt8(arc & 0x7F)]
                var rest = arc >> 7
                while rest > 0 {
                    chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                    rest >>= 7
                }
                body.append(contentsOf: chunk)
            }
            return element(0x06, body)
        }

        /// UTCTime through 2049, GeneralizedTime after, as RFC 5280 asks.
        static func time(_ date: Date) -> Data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
            if year < 2050 {
                formatter.dateFormat = "yyMMddHHmmss'Z'"
                return element(0x17, Data(formatter.string(from: date).utf8))
            }
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return element(0x18, Data(formatter.string(from: date).utf8))
        }

        static func element(_ tag: UInt8, _ content: Data) -> Data {
            var data = Data([tag])
            let length = content.count
            if length < 0x80 {
                data.append(UInt8(length))
            } else {
                var bytes: [UInt8] = []
                var rest = length
                while rest > 0 {
                    bytes.insert(UInt8(rest & 0xFF), at: 0)
                    rest >>= 8
                }
                data.append(0x80 | UInt8(bytes.count))
                data.append(contentsOf: bytes)
            }
            return data + content
        }
    }
}
