import Foundation
import Security

/// The TLS identity the Mac serves the mobile companion with: a P-256 key and a
/// self-signed certificate, made on first use and kept in the login keychain. Devices
/// pin the certificate's fingerprint when they pair, so it must outlive app updates.
///
/// The key carries our label; the keychain ignores labels on certificates, so the
/// certificate is found by the hash of the key's public half, which both share.
enum RemoteIdentity {
    enum Failure: Error, LocalizedError {
        case keychain(OSStatus, String)
        case key(String)

        var errorDescription: String? {
            switch self {
            case .keychain(let status, let step):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "Keychain error while \(step): \(message)"
            case .key(let message):
                return "Could not make a key: \(message)"
            }
        }
    }

    /// Apart for each build, so Maggie Dev's identity isn't Maggie's.
    static var label: String {
        labelForTesting ?? "\(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty").remote"
    }

    /// Lets tests keep their identity apart from the app's.
    nonisolated(unsafe) static var labelForTesting: String?

    /// The identity, made now if there is none yet.
    static func loadOrCreate() throws -> (identity: SecIdentity, fingerprint: CertificateFingerprint) {
        if let keyHash = try existingKeyHash() {
            if let certificate = try certificate(forKeyHash: keyHash), let identity = identity(for: certificate) {
                return (identity, fingerprint(of: certificate))
            }
            // A key without its certificate is of no use: start over.
            RemoteService.logger.error("the remote key has no certificate; making a new identity")
            delete()
        }

        let certificate = try create()
        guard let identity = identity(for: certificate) else {
            throw Failure.keychain(errSecItemNotFound, "finding the new identity")
        }
        RemoteService.logger.info("made a new TLS identity for the mobile companion")
        return (identity, fingerprint(of: certificate))
    }

    static func fingerprint(of certificate: SecCertificate) -> CertificateFingerprint {
        CertificateFingerprint(certificate: SecCertificateCopyData(certificate) as Data)
    }

    /// The public key hash of our private key, if there is one.
    private static func existingKeyHash() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrLabel: label,
            kSecReturnAttributes: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = result as? [CFString: Any] else {
            throw Failure.keychain(status, "reading the key")
        }
        return attributes[kSecAttrApplicationLabel] as? Data
    }

    private static func certificate(forKeyHash hash: Data) throws -> SecCertificate? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrPublicKeyHash: hash,
            kSecReturnRef: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecCertificateGetTypeID() else {
            throw Failure.keychain(status, "reading the certificate")
        }
        // Checked by type ID just above.
        return (result as! SecCertificate) // swiftlint:disable:this force_cast
    }

    private static func identity(for certificate: SecCertificate) -> SecIdentity? {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        return status == errSecSuccess ? identity : nil
    }

    private static func create() throws -> SecCertificate {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrLabel: label,
            ],
        ] as CFDictionary, &error) else {
            throw Failure.key(error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown")
        }

        let host = Host.current().localizedName ?? "Mac"
        let der = try SelfSignedCertificate.make(privateKey: key, commonName: "\(Maggie.branded("Ghostty")) Mobile on \(host)")
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw Failure.key("the certificate did not parse")
        }

        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Failure.keychain(status, "saving the certificate")
        }
        return certificate
    }

    /// Forgets the identity. Every paired device then has to pair again.
    static func delete() {
        if let hash = try? existingKeyHash() {
            SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: hash] as CFDictionary)
        }
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrLabel: label] as CFDictionary)
    }
}
