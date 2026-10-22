import Foundation
import Testing
@testable import Ghostty

@Suite
@MainActor
struct RemotePairingTests {
    private let fingerprint = CertificateFingerprint(certificate: Data("cert".utf8))
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aCodeWorksOnce() {
        let pairing = RemotePairing()
        let offer = pairing.begin(host: "mac", port: 7788, fingerprint: fingerprint, name: nil, now: start)
        #expect(offer.invitation.host == "mac")
        #expect(PairingInvitation(url: offer.invitation.url) == offer.invitation)

        #expect((try? pairing.redeem(code: offer.code, now: start.addingTimeInterval(10)).get()) != nil)
        #expect(pairing.offer == nil)
        guard case .failure(let error) = pairing.redeem(code: offer.code, now: start.addingTimeInterval(20)) else {
            Issue.record("a used code paired again")
            return
        }
        #expect(error.code == .pairingCodeInvalid)
    }

    @Test func aCodeExpiresAfterFiveMinutes() {
        let pairing = RemotePairing()
        let offer = pairing.begin(host: "mac", port: 7788, fingerprint: fingerprint, name: nil, now: start)
        guard case .failure(let error) = pairing.redeem(code: offer.code, now: start.addingTimeInterval(5 * 60 + 1)) else {
            Issue.record("an expired code paired")
            return
        }
        #expect(error.code == .pairingCodeExpired)
        #expect(pairing.offer == nil)
    }

    @Test func wrongGuessesUseTheCodeUp() {
        let pairing = RemotePairing()
        let offer = pairing.begin(host: "mac", port: 7788, fingerprint: fingerprint, name: nil, now: start)
        let wrong = offer.code == "000000" ? "111111" : "000000"
        for _ in 0..<(RemotePairing.attempts - 1) {
            _ = pairing.redeem(code: wrong, now: start)
        }
        #expect(pairing.offer != nil)
        _ = pairing.redeem(code: wrong, now: start)
        #expect(pairing.offer == nil)
        guard case .failure = pairing.redeem(code: offer.code, now: start) else {
            Issue.record("the right code paired after the guesses ran out")
            return
        }
    }
}

@Suite
@MainActor
struct RemoteDeviceStoreTests {
    private func withFile(_ body: (URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maggie-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("devices.json"))
    }

    @Test func tokensAreCheckedByHashAndKept() throws {
        try withFile { file in
            let store = RemoteDeviceStore(file: file)
            let (device, token) = store.add(name: "iPad")
            #expect(store.device(forToken: token)?.id == device.id)
            #expect(store.device(forToken: token + "x") == nil)

            // Only the hash is written down.
            let written = try String(contentsOf: file, encoding: .utf8)
            #expect(!written.contains(token))
            #expect(written.contains(DeviceToken.hash(token)))

            // And it is there after a restart.
            #expect(RemoteDeviceStore(file: file).device(forToken: token)?.name == "iPad")
        }
    }

    @Test func removedDevicesAreRefused() {
        withFile { file in
            let store = RemoteDeviceStore(file: file)
            let (device, token) = store.add(name: "iPhone")
            store.update(id: device.id) { $0.pushToken = "abcd" }
            #expect(store.device(id: device.id)?.pushToken == "abcd")
            store.remove(id: device.id)
            #expect(store.device(forToken: token) == nil)
            #expect(RemoteDeviceStore(file: file).devices.isEmpty)
        }
    }
}

@Suite
@MainActor
struct RemoteSessionFeedTests {
    /// Objects standing in for tab windows, kept alive so their ids stay distinct.
    private let windows = (0..<4).map { _ in NSObject() }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func tab(_ index: Int, title: String, light: ClaudeCodeLight?, groupID: UUID? = nil, folderID: UUID? = nil) -> TabSidebarModel.Tab {
        var activity = ClaudeCodeActivity()
        if let light {
            activity.update(from: .clean, to: light, at: now, seen: false)
        }
        return TabSidebarModel.Tab(
            id: ObjectIdentifier(windows[index]),
            index: index,
            title: title,
            color: light?.tabColor ?? .none,
            assignedColor: .auto,
            claudeCodeState: light.map { ClaudeCodeTabState(light: $0, pendingFiles: 3) },
            claudeCodeActivity: activity,
            canSpeak: false,
            isSpeaking: false,
            speechVoiceID: nil,
            keyEquivalent: nil,
            isSelected: index == 0,
            isZoomed: false,
            groupID: groupID,
            folderID: folderID,
            folderGroupID: nil)
    }

    private func context(info: [Int: TabSidebarSessionInfo] = [:], git: Set<String> = []) -> RemoteSessionFeed.Context {
        RemoteSessionFeed.Context(
            id: { tab in "session-\(tab.index)" },
            info: { tab in info[tab.index] },
            bell: { tab in tab.index == 1 },
            hasGit: { git.contains($0) })
    }

    @Test func snapshotKeepsTheSidebarTree() {
        let group = UserTabGroup(name: "Reviews", color: .purple, isCollapsed: true)
        let folder = UserTabFolder(name: "ghostty", path: "/Users/me/ghostty")
        let empty = UserTabFolder(name: "notes", path: "/Users/me/notes")
        let folderGroup = UserTabFolderGroup(name: "Work")
        let rows: [TabSidebarModel.Row] = [
            .tab(tab(0, title: "loose", light: .working)),
            .group(.init(group: group, tabs: [tab(1, title: "grouped", light: .waiting, groupID: group.id)])),
            .folder(.init(folder: folder, rows: [.tab(tab(2, title: "in folder", light: .pending, folderID: folder.id))])),
            .folderGroup(.init(group: folderGroup, folders: [.init(folder: empty, rows: [])])),
        ]

        var info = TabSidebarSessionInfo()
        info.model = "opus"
        info.directory = "/Users/me/ghostty"
        info.checkout = Git.parseCheckout("/Users/me/ghostty\n/Users/me/ghostty/.git\n/Users/me/ghostty/.git\nmain")
        let snapshot = RemoteSessionFeed.snapshot(rows: rows, context: context(info: [2: info], git: ["/Users/me/ghostty"]))

        #expect(snapshot.rows.map(\.id) == ["session-session-0", "group-\(group.id.uuidString)", "folder-\(folder.id.uuidString)", "folders-\(folderGroup.id.uuidString)"])
        #expect(snapshot.sessions.map(\.title) == ["loose", "grouped", "in folder"])
        #expect(snapshot.folders.map(\.name) == ["ghostty", "notes"])
        #expect(snapshot.folders.map(\.hasGit) == [true, false])

        let working = snapshot.session(id: "session-0")
        #expect(working?.light == .working)
        #expect(working?.workingSince == now)
        #expect(working?.isSelected == true)

        let waiting = snapshot.session(id: "session-1")
        #expect(waiting?.light == .waiting)
        #expect(waiting?.bell == true)
        #expect(waiting?.lightLabel == "Waiting for you")

        let pending = snapshot.session(id: "session-2")
        #expect(pending?.badge == 3)
        #expect(pending?.model == "opus")
        #expect(pending?.branch == "main")
        #expect(pending?.isWorktree == false)
        #expect(pending?.statusText(at: now) == "3")

        guard case .group(let shownGroup) = snapshot.rows[1] else {
            Issue.record("the group is missing")
            return
        }
        #expect(shownGroup.collapsed)
        #expect(shownGroup.color == .purple)
    }

    @Test func aFolderInTwoWindowsIsListedOnce() {
        let folder = UserTabFolder(name: "ghostty", path: "/Users/me/ghostty")
        let rows: [TabSidebarModel.Row] = [
            .folder(.init(folder: folder, rows: [.tab(tab(0, title: "a", light: nil, folderID: folder.id))])),
            .folder(.init(folder: folder, rows: [.tab(tab(1, title: "b", light: nil, folderID: folder.id))])),
        ]
        let snapshot = RemoteSessionFeed.snapshot(rows: rows, context: context())
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.sessions.map(\.title) == ["a", "b"])
    }

    @Test func eachWindowIsSentWithItsOwnRows() {
        let folder = UserTabFolder(name: "ghostty", path: "/Users/me/ghostty")
        let windows: [RemoteSessionFeed.Window] = [
            .init(id: "w1", name: "Work", title: "Work", isFront: false, rows: [
                .folder(.init(folder: folder, rows: [.tab(tab(0, title: "a", light: nil, folderID: folder.id))])),
            ]),
            .init(id: "w2", name: nil, title: "build", isFront: true, rows: [
                .tab(tab(1, title: "build", light: nil)),
                .folder(.init(folder: folder, rows: [.tab(tab(2, title: "b", light: nil, folderID: folder.id))])),
            ]),
        ]
        let snapshot = RemoteSessionFeed.snapshot(windows: windows, context: context())

        // All windows together, as before, with the shared folder once.
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.sessions.map(\.title) == ["a", "b", "build"])

        // Each window by title, with only its own sessions.
        #expect(snapshot.windows.map(\.title) == ["build", "Work"])
        #expect(snapshot.window(id: "w1")?.name == "Work")
        #expect(snapshot.window(id: "w1")?.sessions.map(\.title) == ["a"])
        #expect(snapshot.window(id: "w2")?.sessions.map(\.title) == ["build", "b"])
        #expect(snapshot.window(id: "w2")?.isFront == true)
        #expect(snapshot.window(id: "w2")?.folders.map(\.name) == ["ghostty"])
    }

    @Test func updatesAreSpacedOut() {
        var coalescer = RemoteCoalescer(interval: 0.25)
        #expect(coalescer.delay(at: now) == 0)
        coalescer.fired(at: now)
        #expect(abs(coalescer.delay(at: now.addingTimeInterval(0.1)) - 0.15) < 0.001)
        #expect(coalescer.delay(at: now.addingTimeInterval(1)) == 0)
    }

    @Test func sessionIDsLastAsLongAsTheirWindow() {
        let ids = RemoteSessionIDs()
        #expect(ids.id(for: ObjectIdentifier(windows[0])) == nil)
    }
}

@Suite
struct RemoteIdentityTests {
    /// Devices pin the certificate, so loading again must find the same one, not make
    /// another.
    @Test func theIdentityIsKept() throws {
        RemoteIdentity.labelForTesting = "com.mitchellh.ghostty.tests.remote-\(UUID().uuidString)"
        defer {
            RemoteIdentity.delete()
            RemoteIdentity.labelForTesting = nil
        }

        let first = try RemoteIdentity.loadOrCreate()
        let second = try RemoteIdentity.loadOrCreate()
        #expect(first.fingerprint == second.fingerprint)

        var certificate: SecCertificate?
        SecIdentityCopyCertificate(second.identity, &certificate)
        #expect(certificate.map(RemoteIdentity.fingerprint(of:)) == first.fingerprint)
    }
}

@Suite
struct RemoteAddressesTests {
    @Test func tailscaleAndLocalRanges() {
        #expect(RemoteAddresses.kind(of: [100, 101, 2, 3]) == .tailscale)
        #expect(RemoteAddresses.kind(of: [100, 63, 2, 3]) == nil)
        #expect(RemoteAddresses.kind(of: [192, 168, 1, 20]) == .local)
        #expect(RemoteAddresses.kind(of: [172, 20, 1, 1]) == .local)
        #expect(RemoteAddresses.kind(of: [10, 0, 0, 1]) == .local)
        #expect(RemoteAddresses.kind(of: [8, 8, 8, 8]) == nil)
    }

    @Test func tailscaleNameFromStatus() {
        let status = Data(#"{"Self": {"DNSName": "macmini.tail1234.ts.net.", "HostName": "macmini"}}"#.utf8)
        #expect(RemoteAddresses.dnsName(fromStatus: status) == "macmini.tail1234.ts.net")
        #expect(RemoteAddresses.dnsName(fromStatus: Data("{}".utf8)) == nil)
    }
}
