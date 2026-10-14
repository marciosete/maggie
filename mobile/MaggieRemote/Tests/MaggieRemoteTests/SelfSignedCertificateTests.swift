import Foundation
import Security
import Testing
@testable import MaggieRemote

struct SelfSignedCertificateTests {
    private func makeKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, &error)
        return try #require(key)
    }

    @Test func certificateParsesWithItsNameAndKey() throws {
        let key = try makeKey()
        let der = try SelfSignedCertificate.make(privateKey: key, commonName: "Maggie on Test Mac")
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))

        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        #expect(name as String? == "Maggie on Test Mac")

        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        #expect(SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
    }

    @Test func signatureVerifiesWithTheKey() throws {
        let key = try makeKey()
        let der = try SelfSignedCertificate.make(privateKey: key, commonName: "x")
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))

        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        let created = try #require(trust)
        SecTrustSetAnchorCertificates(created, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(created, true)
        #expect(SecTrustEvaluateWithError(created, nil))
    }

    @Test func fingerprintIsOfTheDER() throws {
        let der = try SelfSignedCertificate.make(privateKey: try makeKey(), commonName: "x")
        #expect(CertificateFingerprint(certificate: der).bytes.count == 32)
    }

    @Test func pinningAcceptsOnlyThePairedCertificate() throws {
        let der = try SelfSignedCertificate.make(privateKey: try makeKey(), commonName: "paired")
        let other = try SelfSignedCertificate.make(privateKey: try makeKey(), commonName: "paired")
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))

        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        let secTrust = try #require(trust)
        let presented = try #require(sec_trust_create(secTrust))

        #expect(RemoteTLS.isPinned(presented, to: CertificateFingerprint(certificate: der)))
        #expect(!RemoteTLS.isPinned(presented, to: CertificateFingerprint(certificate: other)))
    }

    @Test func derLengthsAndIntegers() {
        typealias DER = SelfSignedCertificate.DER
        #expect(Array(DER.element(0x04, Data(count: 200)).prefix(3)) == [0x04, 0x81, 200])
        #expect(Array(DER.element(0x04, Data(count: 300)).prefix(4)) == [0x04, 0x82, 0x01, 0x2C])
        #expect(Array(DER.integer([0x80])) == [0x02, 0x02, 0x00, 0x80])
        #expect(Array(DER.integer([0, 0, 5])) == [0x02, 0x01, 0x05])
        #expect(Array(DER.oid([1, 2, 840, 10045, 2, 1])) == [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    }
}
