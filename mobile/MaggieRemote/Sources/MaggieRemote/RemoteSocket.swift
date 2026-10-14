import Foundation
import Network
import Security

/// One WebSocket over TLS, on either side: the Mac wraps each accepted connection in one,
/// the device dials the Mac with one. Text frames are JSON messages, binary frames are
/// `RemoteFrame`s.
///
/// Callbacks run on `queue`. Sending is safe from any thread.
public final class RemoteSocket: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting
        case ready
        case closed(String?)
    }

    public var onState: ((State) -> Void)?
    public var onText: ((Data) -> Void)?
    public var onBinary: ((Data) -> Void)?

    public let connection: NWConnection
    public let queue: DispatchQueue

    private let lock = NSLock()
    private var inFlight = 0
    private var closed = false

    /// Wraps a connection a listener accepted.
    public init(accepted connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Dials the Mac at `host`:`port`, accepting only a certificate with `fingerprint`.
    public convenience init(host: String, port: UInt16, pinning fingerprint: CertificateFingerprint, queue: DispatchQueue) {
        let parameters = RemoteTLS.clientParameters(pinning: fingerprint, queue: queue)
        // The WebSocket upgrade request takes its Host and path from a URL endpoint.
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = Int(port)
        components.path = "/"
        let endpoint = components.url.map(NWEndpoint.url)
            ?? .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .https)
        self.init(accepted: NWConnection(to: endpoint, using: parameters), queue: queue)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState?(.ready)
                self.receive()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .waiting(let error):
                // Unreachable for now: report it and keep the connection's own retry.
                self.onState?(.closed(error.localizedDescription))
                self.cancel()
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    /// Bytes handed to the connection and not yet sent, to tell a slow link.
    public var bytesInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    public func sendText(_ data: Data) {
        send(data, opcode: .text)
    }

    public func sendBinary(_ data: Data) {
        send(data, opcode: .binary)
    }

    /// Closes with a WebSocket close frame, then the connection.
    public func close() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        lock.lock()
        inFlight += data.count
        lock.unlock()

        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.inFlight -= data.count
            self.lock.unlock()
        })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.finish(error.localizedDescription)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text: self.onText?(data ?? Data())
            case .binary: self.onBinary?(data ?? Data())
            case .close:
                self.cancel()
                return
            default: break
            }
            self.receive()
        }
    }

    private func finish(_ reason: String?) {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        onState?(.closed(reason))
        connection.cancel()
    }
}

extension RemoteSocket {
    public func send(_ message: ClientMessage) {
        guard let data = try? RemoteCoding.encode(message) else { return }
        sendText(data)
    }

    public func send(_ message: HostMessage) {
        guard let data = try? RemoteCoding.encode(message) else { return }
        sendText(data)
    }

    public func send(_ frame: RemoteFrame) {
        sendBinary(frame.encoded())
    }
}

/// TLS and WebSocket settings for both ends.
public enum RemoteTLS {
    /// The Mac's listener: TLS with its own identity, then WebSocket.
    public static func serverParameters(identity: SecIdentity) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return parameters(tls: tls)
    }

    /// The device: TLS that trusts exactly one certificate, the one paired with.
    public static func clientParameters(pinning fingerprint: CertificateFingerprint, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(Self.leafFingerprint(of: trust) == fingerprint)
        }, queue)
        return parameters(tls: tls)
    }

    /// The fingerprint of the certificate a peer presented.
    static func leafFingerprint(of trust: sec_trust_t) -> CertificateFingerprint? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return CertificateFingerprint(certificate: SecCertificateCopyData(leaf) as Data)
    }

    private static func parameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 64 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }
}
