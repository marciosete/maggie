import AppKit
import Network
import os

/// The mobile companion's server: Maggie Mobile on a phone or tablet connects here, over
/// Tailscale or the local network, to see the sidebar and steer sessions.
///
/// Off until turned on in Settings → Mobile. One WebSocket per device, over TLS with this
/// Mac's self-signed certificate, which devices pin when they pair. A connection must
/// pair or say hello with a known device token within five seconds, or it is closed.
@MainActor
final class RemoteService: ObservableObject {
    static let shared = RemoteService()

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", category: "remote")

    /// Apart for each build, so Maggie Dev's devices aren't Maggie's.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("Remote", isDirectory: true)
    }

    enum Status: Equatable {
        case off
        case starting
        case listening(UInt16)
        case failed(String)
    }

    private enum Keys {
        static let enabled = "RemoteEnabled"
        static let port = "RemotePort"
        static let host = "RemoteAdvertisedHost"
        static let homeFolder = "RemoteHomeFolder"
    }

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.ghostty.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    @Published var port: UInt16 {
        didSet {
            guard port != oldValue else { return }
            UserDefaults.ghostty.set(Int(port), forKey: Keys.port)
            if isEnabled { start() }
        }
    }

    /// The address the pairing QR code gives devices. Empty uses `suggestedHost`.
    @Published var advertisedHost: String {
        didSet { UserDefaults.ghostty.set(advertisedHost, forKey: Keys.host) }
    }

    /// The folder devices start sessions in and browse below. Empty is the user's home.
    @Published var homeFolderSetting: String {
        didSet { UserDefaults.ghostty.set(homeFolderSetting, forKey: Keys.homeFolder) }
    }

    /// `homeFolderSetting` as a folder that exists, else the user's home.
    var homeFolder: URL {
        let path = (homeFolderSetting as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    /// The best address found for this Mac, preferring its Tailscale name.
    @Published private(set) var suggestedHost: String
    @Published private(set) var addresses: [RemoteAddresses.Address] = []
    @Published private(set) var status: Status = .off
    @Published private(set) var fingerprint: CertificateFingerprint?

    /// The devices connected now, by device id.
    @Published private(set) var connectedDevices: Set<String> = [] {
        didSet { push.connectedDevices = connectedDevices }
    }

    let devices: RemoteDeviceStore
    let pairing = RemotePairing()
    let feed: RemoteSessionFeed
    let push: RemotePush

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: RemoteClient] = [:]

    init(devices: RemoteDeviceStore? = nil) {
        let defaults = UserDefaults.ghostty
        let devices = devices ?? RemoteDeviceStore(file: RemoteDeviceStore.defaultFile)
        self.devices = devices
        let feed = RemoteSessionFeed()
        self.feed = feed
        push = RemotePush(devices: devices, ids: feed.ids)
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let savedPort = defaults.integer(forKey: Keys.port)
        port = (1...65535).contains(savedPort) ? UInt16(savedPort) : RemoteProtocol.defaultPort
        advertisedHost = defaults.string(forKey: Keys.host) ?? ""
        homeFolderSetting = defaults.string(forKey: Keys.homeFolder) ?? ""
        suggestedHost = Host.current().localizedName ?? "localhost"

        feed.onChange = { [weak self] snapshot in
            self?.clients.values.filter(\.subscribedToSidebar).forEach { $0.send(.sidebar(snapshot)) }
        }
    }

    /// Called once the app has launched.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    var invitationHost: String {
        let host = advertisedHost.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? suggestedHost : host
    }

    // MARK: Listening

    private func start() {
        stopListening()
        status = .starting
        refreshAddresses()

        let identity: SecIdentity
        do {
            let loaded = try RemoteIdentity.loadOrCreate()
            identity = loaded.identity
            fingerprint = loaded.fingerprint
        } catch {
            Self.logger.error("no TLS identity: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            return
        }

        do {
            let parameters = RemoteTLS.serverParameters(identity: identity)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Self.logger.error("could not listen on \(self.port): \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        stopListening()
        pairing.cancel()
        status = .off
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.close() }
        clients = [:]
        connectedDevices = []
        feed.setActive(false)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = .listening(listener?.port?.rawValue ?? port)
            Self.logger.info("listening on \(self.port)")
        case .failed(let error):
            Self.logger.error("listener failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = RemoteClient(socket: RemoteSocket(accepted: connection, queue: .main), service: self)
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    // MARK: Clients

    func clientClosed(_ client: RemoteClient) {
        clients[ObjectIdentifier(client)] = nil
        clientsChanged()
    }

    func clientsChanged() {
        connectedDevices = Set(clients.values.compactMap(\.device?.id))
        feed.setActive(clients.values.contains(where: \.subscribedToSidebar))
    }

    /// Forgets a device and drops its connections.
    func removeDevice(id: String) {
        devices.remove(id: id)
        clients.values.filter { $0.device?.id == id }.forEach { $0.close() }
    }

    // MARK: Pairing

    /// Shows a new pairing code, for the QR code in Settings.
    @discardableResult
    func beginPairing() -> RemotePairingOffer? {
        guard case .listening(let port) = status, let fingerprint else { return nil }
        // The Mac may have moved networks since the addresses were read.
        refreshAddresses()
        return pairing.begin(host: invitationHost, port: port, fingerprint: fingerprint, name: Host.current().localizedName)
    }

    /// The Mac's Tailscale name, once read. It stays the same on any network.
    private var tailscaleName: String?

    func refreshAddresses() {
        addresses = RemoteAddresses.current()
        if let tailscaleName {
            addresses.insert(RemoteAddresses.Address(kind: .tailscale, value: tailscaleName), at: 0)
        }
        if let best = addresses.first { suggestedHost = best.value }
        DispatchQueue.global(qos: .utility).async {
            let name = RemoteAddresses.tailscaleName()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let name else { return }
                    self.tailscaleName = name
                    self.suggestedHost = name
                    if !self.addresses.contains(where: { $0.value == name }) {
                        self.addresses.insert(RemoteAddresses.Address(kind: .tailscale, value: name), at: 0)
                    }
                }
            }
        }
    }
}

/// One device's connection.
@MainActor
final class RemoteClient {
    let socket: RemoteSocket
    private weak var service: RemoteService?

    /// The paired device, once it said hello or paired.
    private(set) var device: RemoteDevice?
    private(set) var subscribedToSidebar = false

    /// The window whose board the device last asked for; none for every window's.
    private var boardWindowID: String?
    private var helloTimer: Timer?

    /// The sessions this device mirrors.
    private let streams: RemoteTerminalStreams

    /// The voice, as this device sees and carries it.
    private let voice: RemoteVoiceBridge

    init(socket: RemoteSocket, service: RemoteService) {
        self.socket = socket
        self.service = service
        streams = RemoteTerminalStreams(socket: socket, feed: service.feed)
        voice = RemoteVoiceBridge(socket: socket)
        streams.onClosed = { [weak self] closed in self?.send(.sessionClosed(closed)) }
    }

    func start() {
        socket.onState = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    // The device has five seconds from here, its handshake done.
                    self.expectHello(within: RemoteProtocol.helloTimeout)
                case .closed:
                    self.helloTimer?.invalidate()
                    self.streams.closeAll()
                    self.voice.closed()
                    self.service?.clientClosed(self)
                case .connecting:
                    break
                }
            }
        }
        socket.onText = { [weak self] data in
            MainActor.assumeIsolated { self?.received(data) }
        }
        socket.onBinary = { [weak self] data in
            MainActor.assumeIsolated {
                guard let self, self.device != nil, let frame = try? RemoteFrame(decoding: data) else { return }
                if self.voice.received(frame) { return }
                self.streams.input(frame)
            }
        }
        socket.start()

        // A handshake that never finishes is let go too.
        expectHello(within: 30)
    }

    private func expectHello(within seconds: TimeInterval) {
        helloTimer?.invalidate()
        helloTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.device == nil else { return }
                RemoteService.logger.info("closing a connection that never said hello")
                self.close()
            }
        }
    }

    func send(_ message: HostMessage) {
        socket.send(message)
    }

    /// Closes the connection. Its taps go first, while their mirrors are still alive.
    func close() {
        streams.closeAll()
        socket.close()
    }

    private func received(_ data: Data) {
        let message: ClientMessage
        do {
            message = try RemoteCoding.decode(ClientMessage.self, from: data)
        } catch RemoteProtocolError.unknownKind(let kind) {
            RemoteService.logger.info("ignoring a message of unknown kind \(kind, privacy: .public)")
            return
        } catch {
            send(.error(RemoteError(code: .badRequest, message: "Could not read the message.")))
            return
        }

        guard let device else {
            switch message {
            case .pair(let request): handlePair(request)
            case .hello(let hello): handleHello(hello)
            default:
                send(.error(RemoteError(code: .unauthorized, message: "Say hello first.")))
                close()
            }
            return
        }
        handle(message, from: device)
    }

    private func handlePair(_ request: PairRequest) {
        guard let service else { return }
        switch service.pairing.redeem(code: request.code) {
        case .failure(let error):
            RemoteService.logger.info("refused a pairing: \(error.code.rawValue, privacy: .public)")
            send(.error(error))
            close()
        case .success:
            let (device, token) = service.devices.add(name: request.deviceName)
            RemoteService.logger.info("paired \(device.name, privacy: .public)")
            authenticated(device)
            send(.paired(Paired(deviceToken: token, deviceID: device.id, hostName: Host.current().localizedName ?? "Mac")))
        }
    }

    private func handleHello(_ hello: Hello) {
        guard let service, let device = service.devices.device(forToken: hello.deviceToken) else {
            RemoteService.logger.info("refused a hello with an unknown token")
            send(.error(RemoteError(code: .unauthorized, message: "This device isn't paired with the Mac, or was removed. Pair it again.")))
            close()
            return
        }
        if hello.deviceName != device.name {
            service.devices.update(id: device.id) { $0.name = hello.deviceName }
        }
        authenticated(device)
        var capabilities = Self.capabilities
        if service.push.isEnabled, service.push.isConfigured { capabilities.append(RemoteCapability.push) }
        send(.welcome(Welcome(hostName: Host.current().localizedName ?? "Mac", capabilities: capabilities)))
    }

    static let capabilities = [
        "sidebar", "newSession", "terminal", "board", "usage",
        RemoteCapability.fitSession, RemoteCapability.homeFolder, RemoteCapability.voice,
    ]

    private func sendBoard() {
        guard let feed = service?.feed else { return }
        send(.board(RemoteBoard.snapshot(
            tabs: feed.tabs(inWindow: boardWindowID),
            items: RemoteBoard.items(WorkItemStore.shared.items, window: boardWindowID),
            settings: .shared,
            id: { tab in tab.window.map(feed.ids.id(for:)) ?? tab.id.debugDescription })))
    }

    private func authenticated(_ device: RemoteDevice) {
        helloTimer?.invalidate()
        self.device = device
        streams.deviceName = device.name
        service?.devices.update(id: device.id) { $0.lastSeen = Date() }
        service?.clientsChanged()
    }

    private func handle(_ message: ClientMessage, from device: RemoteDevice) {
        guard let service else { return }
        switch message {
        case .pair, .hello:
            send(.error(RemoteError(code: .badRequest, message: "Already paired.")))

        case .subscribeSidebar:
            subscribedToSidebar = true
            service.clientsChanged()
            service.feed.update()
            send(.sidebar(service.feed.snapshot))

        case .newSession(let request):
            switch RemoteCommands.newSession(request, home: service.homeFolder, feed: service.feed) {
            case .success(let created): send(.sessionCreated(created))
            case .failure(let error): send(.error(error))
            }

        case .listFolders(let request):
            switch RemoteFolders.list(request.path, home: service.homeFolder) {
            case .success(let listing): send(.folders(listing))
            case .failure(let error): send(.error(error))
            }

        case .fitSession(let request):
            if !streams.fit(request) {
                send(.sessionClosed(SessionClosed(id: request.id, reason: .notFound)))
            }

        case .focusSession(let ref):
            if !RemoteCommands.focus(sessionID: ref.id, feed: service.feed) {
                send(.sessionClosed(SessionClosed(id: ref.id, reason: .notFound)))
            }

        case .closeSession(let request):
            let reason = RemoteCommands.close(sessionID: request.id, force: request.force, feed: service.feed)
            send(.sessionClosed(SessionClosed(id: request.id, reason: reason)))

        case .openSession(let ref):
            if case .failure = streams.open(sessionID: ref.id) {
                send(.sessionClosed(SessionClosed(id: ref.id, reason: .notFound)))
            }

        case .leaveSession(let ref):
            streams.leave(sessionID: ref.id)
            send(.sessionClosed(SessionClosed(id: ref.id, reason: .left)))

        case .resyncSession(let ref):
            if !streams.resync(sessionID: ref.id), case .failure = streams.open(sessionID: ref.id) {
                send(.sessionClosed(SessionClosed(id: ref.id, reason: .notFound)))
            }

        case .registerPush(let push):
            service.devices.update(id: device.id) {
                $0.pushToken = push.token
                $0.pushEnvironment = push.environment
            }

        case .ping(let ping):
            send(.pong(ping))

        case .fetchBoard(let request):
            boardWindowID = request.windowID
            sendBoard()

        case .moveCard(let request):
            if !RemoteBoard.move(request, tabs: service.feed.tabs(inWindow: boardWindowID), feed: service.feed) {
                send(.error(RemoteError(code: .notFound, message: "That card or column is no longer on the Mac's board.")))
            }
            sendBoard()

        case .fetchUsage:
            Task { [weak self] in
                guard let report = await RemoteUsage.current() else {
                    self?.send(.error(RemoteError(code: .notFound, message: "The Mac has no usage to show yet.")))
                    return
                }
                self?.send(.usage(report))
            }

        case .renameSession(let request):
            guard let controller = service.feed.ids.window(for: request.id)?.terminalController else {
                send(.sessionClosed(SessionClosed(id: request.id, reason: .notFound)))
                return
            }
            let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
            controller.titleOverride = title.isEmpty ? nil : title
            service.feed.setNeedsUpdate()

        case .peekSession(let ref):
            if let peek = RemotePeek.peek(sessionID: ref.id, feed: service.feed) {
                send(.sessionPeek(peek))
            } else {
                send(.sessionClosed(SessionClosed(id: ref.id, reason: .notFound)))
            }

        case .startVoice, .stopVoice, .muteVoice, .subscribeVoice:
            _ = voice.handle(message)
        }
    }
}
