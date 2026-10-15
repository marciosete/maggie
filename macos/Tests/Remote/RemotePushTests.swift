import CryptoKit
import Foundation
import Testing
@testable import Ghostty

@Suite
struct RemotePushRulesTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func waitingAndFinishingAreWorthAPush() {
        var rules = RemotePushRules()
        #expect(rules.notice(from: .working, to: .waiting, session: "a", at: now)?.light == .waiting)
        #expect(rules.notice(from: .working, to: .clean, session: "b", at: now)?.light == .clean)
        #expect(rules.notice(from: .working, to: .pending, session: "c", at: now) != nil)
        #expect(rules.notice(from: .working, to: .unlanded, session: "d", at: now) != nil)
        #expect(rules.notice(from: .clean, to: .waiting, session: "e", at: now) != nil)
    }

    @Test func otherChangesAreNot() {
        var rules = RemotePushRules()
        #expect(rules.notice(from: .waiting, to: .working, session: "a", at: now) == nil)
        #expect(rules.notice(from: .pending, to: .clean, session: "a", at: now) == nil)
        #expect(rules.notice(from: nil, to: .waiting, session: "a", at: now) == nil)
        #expect(rules.notice(from: .waiting, to: .waiting, session: "a", at: now) == nil)
        #expect(rules.notice(from: .working, to: nil, session: "a", at: now) == nil)
    }

    @Test func oneASessionEveryThirtySeconds() {
        var rules = RemotePushRules()
        #expect(rules.notice(from: .working, to: .waiting, session: "a", at: now) != nil)
        #expect(rules.notice(from: .working, to: .clean, session: "a", at: now.addingTimeInterval(10)) == nil)
        #expect(rules.notice(from: .working, to: .clean, session: "b", at: now.addingTimeInterval(10)) != nil)
        #expect(rules.notice(from: .working, to: .clean, session: "a", at: now.addingTimeInterval(31)) != nil)
    }
}

@Suite
struct RemotePushCredentialsTests {
    @Test func theTokenVerifiesWithThePublicKey() throws {
        let key = P256.Signing.PrivateKey()
        var credentials = RemotePushCredentials(key: key, keyID: "ABC123DEFG", teamID: "TEAM123456")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jwt = try credentials.jwt(at: now)

        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let header = try #require(try JSONSerialization.jsonObject(with: Self.decode(parts[0])) as? [String: Any])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABC123DEFG")
        let claims = try #require(try JSONSerialization.jsonObject(with: Self.decode(parts[1])) as? [String: Any])
        #expect(claims["iss"] as? String == "TEAM123456")
        #expect(claims["iat"] as? Int == 1_700_000_000)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Self.decode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        #expect(!parts.joined().contains("="))
    }

    @Test func theTokenIsKeptFiftyMinutes() throws {
        var credentials = RemotePushCredentials(key: P256.Signing.PrivateKey(), keyID: "K", teamID: "T")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jwt = try credentials.jwt(at: now)
        #expect(credentials.validJWT(at: now.addingTimeInterval(49 * 60)) == jwt)
        #expect(credentials.validJWT(at: now.addingTimeInterval(51 * 60)) == nil)
    }

    static func decode(_ base64URL: String) throws -> Data {
        var base64 = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return try #require(Data(base64Encoded: base64))
    }
}

/// A stand-in for APNs, answering every request with `status`.
final class FakeAPNs: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/2", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct RemotePushDeliveryTests {
    private struct Fixture {
        let push: RemotePush
        let store: RemoteDeviceStore
        let deviceID: String
        let directory: URL
    }

    private func makePush() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maggie-push-\(UUID().uuidString)")
        let store = RemoteDeviceStore(file: directory.appendingPathComponent("devices.json"))
        let (device, _) = store.add(name: "iPhone")
        store.update(id: device.id) {
            $0.pushToken = "abcdef0123"
            $0.pushEnvironment = .sandbox
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeAPNs.self]
        let push = RemotePush(devices: store, ids: RemoteSessionIDs(), session: URLSession(configuration: configuration), keyFile: directory.appendingPathComponent("AuthKey.p8"))
        let keyFile = directory.appendingPathComponent("key-source.p8")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try P256.Signing.PrivateKey().pemRepresentation.write(to: keyFile, atomically: true, encoding: .utf8)
        try push.importKey(from: keyFile)
        push.keyID = "KEY1234567"
        push.teamID = "TEAM123456"
        push.topic = "com.marciosete.maggie.mobile"
        return Fixture(push: push, store: store, deviceID: device.id, directory: directory)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aNotificationReachesAPNsAsItExpects() async throws {
        FakeAPNs.status = 200
        FakeAPNs.requests = []
        let fixture = try makePush()
        let push = fixture.push
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        push.send(RemotePushRules.Notice(session: "S1", light: .waiting), title: "Fix the build")
        await waitFor { !FakeAPNs.requests.isEmpty }

        let (request, body) = try #require(FakeAPNs.requests.first)
        #expect(request.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/abcdef0123")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "com.marciosete.maggie.mobile")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let aps = try #require(json["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Fix the build")
        #expect(alert["body"] as? String == "Waiting for you")
        #expect(aps["thread-id"] as? String == "S1")
        #expect(json["session"] as? String == "S1")
    }

    @Test func aGoneTokenIsRetired() async throws {
        FakeAPNs.status = 410
        FakeAPNs.requests = []
        let fixture = try makePush()
        let (push, store, deviceID) = (fixture.push, fixture.store, fixture.deviceID)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        push.send(RemotePushRules.Notice(session: "S1", light: .clean), title: "Done thing")
        await waitFor { store.device(id: deviceID)?.pushToken == nil }
        #expect(store.device(id: deviceID)?.pushToken == nil)
    }

    @Test func nothingIsSentWithoutAKey() throws {
        FakeAPNs.requests = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maggie-push-\(UUID().uuidString)")
        let store = RemoteDeviceStore(file: directory.appendingPathComponent("devices.json"))
        let push = RemotePush(devices: store, ids: RemoteSessionIDs(), keyFile: directory.appendingPathComponent("AuthKey.p8"))
        #expect(!push.isConfigured)
        #expect(throws: (any Error).self) { try push.importKey(from: URL(fileURLWithPath: "/etc/hosts")) }
    }
}
