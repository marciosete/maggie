import Foundation
import Testing
@testable import MaggieRemote

struct PairingTests {
    static let fingerprint = CertificateFingerprint(certificate: Data("certificate".utf8))

    @Test func invitationRoundTripsThroughItsURL() throws {
        let invitation = PairingInvitation(host: "macmini.tail1234.ts.net", port: 7788, fingerprint: Self.fingerprint, code: "042137", name: "Marcio's Mac mini")
        let url = invitation.url
        #expect(url.absoluteString.hasPrefix("maggie://pair?host=macmini.tail1234.ts.net&port=7788&fp="))
        #expect(PairingInvitation(url: url) == invitation)
        #expect(PairingInvitation(string: "  \(url.absoluteString)\n") == invitation)
    }

    @Test func invitationWithoutNameRoundTrips() {
        let invitation = PairingInvitation(host: "100.64.0.1", port: 9000, fingerprint: Self.fingerprint, code: "000001")
        #expect(PairingInvitation(url: invitation.url) == invitation)
    }

    @Test(arguments: [
        "https://pair?host=a&port=1&fp=00&code=1",
        "maggie://other?host=a&port=1&code=1",
        "maggie://pair?port=7788&code=1",
        "maggie://pair?host=a&port=99999&code=1",
        "maggie://pair?host=a&port=7788&fp=abcd&code=1",
        "not a url",
    ])
    func rejectsWhatIsNotAnInvitation(_ string: String) {
        #expect(PairingInvitation(string: string) == nil)
    }

    @Test func fingerprintAcceptsColonsAndCase() throws {
        let display = Self.fingerprint.displayString
        #expect(display.count == 32 * 3 - 1)
        #expect(CertificateFingerprint(hex: display) == Self.fingerprint)
        #expect(CertificateFingerprint(hex: Self.fingerprint.hex.uppercased()) == Self.fingerprint)
        let data = try RemoteCoding.encode([Self.fingerprint])
        let decoded = try RemoteCoding.decode([CertificateFingerprint].self, from: data)
        #expect(decoded == [Self.fingerprint])
    }

    @Test func tokensAreRandomAndHashed() {
        let first = DeviceToken.generate()
        let second = DeviceToken.generate()
        #expect(first != second)
        #expect(first.count == 43)
        #expect(!first.contains("+") && !first.contains("/") && !first.contains("="))
        #expect(DeviceToken.hash(first) == DeviceToken.hash(first))
        #expect(DeviceToken.hash(first) != DeviceToken.hash(second))
        #expect(DeviceToken.hash(first).count == 64)
    }

    @Test func pairingCodesAreSixDigits() {
        for _ in 0..<100 {
            let code = PairingCode.generate()
            #expect(code.count == 6)
            #expect(Int(code) != nil)
        }
    }
}
