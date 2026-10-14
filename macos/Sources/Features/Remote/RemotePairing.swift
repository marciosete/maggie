import Foundation

/// A phone or tablet paired with this Mac. Only the hash of its token is kept.
struct RemoteDevice: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let tokenHash: String
    let pairedAt: Date
    var lastSeen: Date?

    /// Its Apple Push Notification service token, once it sent one.
    var pushToken: String?
    var pushEnvironment: RegisterPush.Environment?
}

/// The paired devices, kept in Application Support so each build (Maggie, Maggie Dev)
/// has its own.
@MainActor
final class RemoteDeviceStore: ObservableObject {
    @Published private(set) var devices: [RemoteDevice] = []

    private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? RemoteCoding.decode([RemoteDevice].self, from: data) {
            devices = saved
        }
    }

    static var defaultFile: URL {
        RemoteService.directory.appendingPathComponent("devices.json")
    }

    /// Adds a device and returns it with the token it says hello with, which is only
    /// ever known here, in this call.
    func add(name: String, now: Date = Date()) -> (device: RemoteDevice, token: String) {
        let token = DeviceToken.generate()
        let device = RemoteDevice(id: UUID().uuidString, name: name, tokenHash: DeviceToken.hash(token), pairedAt: now, lastSeen: now)
        devices.append(device)
        save()
        return (device, token)
    }

    func device(forToken token: String) -> RemoteDevice? {
        let hash = DeviceToken.hash(token)
        return devices.first { $0.tokenHash == hash }
    }

    func device(id: String) -> RemoteDevice? {
        devices.first { $0.id == id }
    }

    func remove(id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    func update(id: String, _ change: (inout RemoteDevice) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        change(&devices[index])
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try RemoteCoding.encode(devices)
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            RemoteService.logger.error("could not save paired devices: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The pairing code on show, in the QR code or typed in.
struct RemotePairingOffer: Equatable {
    let invitation: PairingInvitation
    let expires: Date

    var code: String { invitation.code }
}

/// Hands out one pairing code at a time and checks the code a device sends back. A code
/// works once, for five minutes, and a few wrong guesses use it up.
@MainActor
final class RemotePairing: ObservableObject {
    @Published private(set) var offer: RemotePairingOffer?

    static let attempts = 5
    private var attemptsLeft = 0

    /// Shows a new code, replacing any other.
    @discardableResult
    func begin(host: String, port: UInt16, fingerprint: CertificateFingerprint, name: String?, now: Date = Date()) -> RemotePairingOffer {
        let invitation = PairingInvitation(host: host, port: port, fingerprint: fingerprint, code: PairingCode.generate(), name: name)
        let offer = RemotePairingOffer(invitation: invitation, expires: now.addingTimeInterval(PairingInvitation.codeLifetime))
        self.offer = offer
        attemptsLeft = Self.attempts
        return offer
    }

    func cancel() {
        offer = nil
    }

    /// Checks a code a device sent. Success uses the code up.
    func redeem(code: String, now: Date = Date()) -> Result<Void, RemoteError> {
        guard let offer else {
            return .failure(RemoteError(code: .pairingCodeInvalid, message: "No pairing code is showing on the Mac."))
        }
        guard now < offer.expires else {
            self.offer = nil
            return .failure(RemoteError(code: .pairingCodeExpired, message: "The pairing code expired. Show a new one on the Mac."))
        }
        guard code == offer.code else {
            attemptsLeft -= 1
            if attemptsLeft <= 0 { self.offer = nil }
            return .failure(RemoteError(code: .pairingCodeInvalid, message: "The pairing code is wrong."))
        }
        self.offer = nil
        return .success(())
    }
}
