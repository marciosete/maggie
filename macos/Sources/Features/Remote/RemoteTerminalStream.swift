import AppKit
import GhosttyKit

/// What waits to go out for one mirrored session, in the order the pty tap gave it:
/// a snapshot, then output and resizes. Output runs are merged into one frame.
///
/// When more piles up than `capacity`, or the link can't keep up, everything waiting is
/// dropped and later output too, until the fresh snapshot asked for arrives. A device
/// that falls behind is brought back by a snapshot rather than an endless backlog.
struct RemoteOutputBuffer {
    enum Item: Equatable {
        case snapshot(columns: UInt16, rows: UInt16, vt: Data)
        case output(Data)
        case resize(columns: UInt16, rows: UInt16)
    }

    enum Outcome: Equatable {
        /// Waits for the next flush.
        case buffered

        /// Enough is waiting, or a snapshot came: flush now.
        case flushNow

        /// Too much was waiting; it was dropped. Ask for a snapshot.
        case overflowed
    }

    /// How much output waits before a flush is not worth waiting for.
    static let flushBytes = 16 * 1024

    let capacity: Int
    private(set) var items: [Item] = []
    private(set) var byteCount = 0

    /// Output was dropped; nothing goes out until a snapshot does.
    private(set) var awaitingSnapshot = false

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ item: Item) -> Outcome {
        switch item {
        case .snapshot(_, _, let vt):
            // A snapshot contains everything before it.
            items = [item]
            byteCount = vt.count
            awaitingSnapshot = false
            return .flushNow

        case .output(let data):
            guard !awaitingSnapshot else { return .buffered }
            if case .output(let waiting) = items.last {
                items[items.count - 1] = .output(waiting + data)
            } else {
                items.append(item)
            }
            byteCount += data.count
            if byteCount > capacity {
                dropForSnapshot()
                return .overflowed
            }
            return byteCount >= Self.flushBytes ? .flushNow : .buffered

        case .resize:
            guard !awaitingSnapshot else { return .buffered }
            items.append(item)
            return .buffered
        }
    }

    /// Takes everything waiting.
    mutating func drain() -> [Item] {
        defer {
            items = []
            byteCount = 0
        }
        return items
    }

    /// Drops what waits and what comes until a snapshot does.
    mutating func dropForSnapshot() {
        items = []
        byteCount = 0
        awaitingSnapshot = true
    }
}

/// One session's terminal mirrored to one device: a pty tap on the session's focused
/// surface, and the frames it turns into.
///
/// The tap calls in on the pty's read thread with the terminal locked, so it only copies
/// into the buffer. A serial queue sends what piled up, every 8 ms or at 16 KB.
final class RemoteMirror: @unchecked Sendable, RemoteFitOwner {
    let stream: UInt32
    let sessionID: String

    /// The most a link may have unsent before the device is resynced with a snapshot.
    static let maxInFlight = 2 * 1024 * 1024
    static let flushDelay: DispatchTimeInterval = .milliseconds(8)

    private let socket: RemoteSocket
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var buffer = RemoteOutputBuffer(capacity: 8 * 1024 * 1024)
    private var flushScheduled = false

    /// The surface being mirrored, through its tap hub. Main thread only.
    private var hub: RemoteTapHub?
    private(set) weak var surfaceView: Ghostty.SurfaceView?

    init(stream: UInt32, sessionID: String, socket: RemoteSocket) {
        self.stream = stream
        self.sessionID = sessionID
        self.socket = socket
        self.queue = DispatchQueue(label: "com.mitchellh.ghostty.remote-mirror-\(stream)", qos: .userInitiated)
    }

    deinit {
        assert(hub == nil, "a mirror must be detached before it goes")
    }

    /// The grid the device asked for, which follows the mirror to another split. Main
    /// thread only.
    private var fit: RemoteFit.Size?

    /// The device's name, for the Mac's note on a terminal it sized. Main thread only.
    private var deviceName = "a device"

    /// Mirrors `view`'s surface, replacing any other, starting with a snapshot.
    @MainActor
    func attach(_ view: Ghostty.SurfaceView) {
        detach()
        guard let model = view.surfaceModel else { return }
        surfaceView = view
        hub = RemoteTapHub.hub(for: model)
        hub?.subscribe(self)
        if let fit { RemoteFit.set(fit, by: self, deviceName: deviceName, on: view) }
    }

    /// Stops mirroring. Nothing more is received after this returns, and the surface
    /// gets back the size it had before this device's fit.
    @MainActor
    func detach() {
        if let surfaceView { RemoteFit.set(nil, by: self, deviceName: deviceName, on: surfaceView) }
        hub?.unsubscribe(self)
        hub = nil
        surfaceView = nil
    }

    /// Sizes the surface to the device's grid, or with nil gives it its own size back.
    @MainActor
    func setFit(_ size: RemoteFit.Size?, deviceName: String) {
        fit = size
        self.deviceName = deviceName
        if let surfaceView { RemoteFit.set(size, by: self, deviceName: deviceName, on: surfaceView) }
    }

    @MainActor
    func requestSnapshot() {
        hub?.requestSnapshot(for: self)
    }

    /// The Mac used the terminal and took its size back: forget the device's grid, so
    /// following focus to another split doesn't ask again, and tell the device.
    @MainActor
    func fitTakenBack() {
        fit = nil
        socket.send(.fitReleased(SessionRef(id: sessionID)))
    }

    /// Bytes the device encoded, straight to the pty.
    @MainActor
    func write(_ data: Data) {
        guard let surface = hub?.surface, !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_surface_pty_write(surface.unsafeCValue, base, UInt(bytes.count))
        }
    }

    /// From the hub, on any thread, with the terminal locked.
    fileprivate func received(_ item: RemoteOutputBuffer.Item) {
        lock.lock()
        let outcome = buffer.append(item)
        let schedule = outcome == .buffered && !flushScheduled
        if schedule || outcome == .flushNow { flushScheduled = true }
        lock.unlock()

        switch outcome {
        case .flushNow:
            queue.async { self.flush() }
        case .buffered where schedule:
            queue.asyncAfter(deadline: .now() + Self.flushDelay) { self.flush() }
        case .buffered:
            break
        case .overflowed:
            DispatchQueue.main.async { MainActor.assumeIsolated { self.requestSnapshot() } }
        }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        // A link that can't keep up gets a snapshot instead of the backlog.
        if socket.bytesInFlight > Self.maxInFlight, !buffer.items.isEmpty {
            buffer.dropForSnapshot()
            lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.requestSnapshot() } }
            return
        }
        let items = buffer.drain()
        lock.unlock()

        for item in items {
            switch item {
            case .snapshot(let columns, let rows, let vt):
                socket.send(.snapshot(stream: stream, columns: columns, rows: rows, vt: vt))
            case .output(let data): socket.send(RemoteFrame(stream: stream, kind: .output, payload: data))
            case .resize(let columns, let rows): socket.send(RemoteFrame.resize(stream: stream, columns: columns, rows: rows))
            }
        }
    }

}

/// The one pty tap on a surface, shared by every mirror of it: one per device that has
/// the session open. A mirror that joins, or falls behind, gets the next snapshot; the
/// others are already in step and skip it, since output after a snapshot follows on
/// from what they have.
final class RemoteTapHub: @unchecked Sendable {
    /// The hubs by surface. Main thread only.
    @MainActor private static var hubs: [ObjectIdentifier: RemoteTapHub] = [:]

    /// Held so the surface outlives its tap. Main thread only.
    let surface: Ghostty.Surface

    private let lock = NSLock()
    private var subscribers: [Subscriber] = []

    private struct Subscriber {
        let mirror: RemoteMirror
        var wantsSnapshot: Bool
    }

    private init(surface: Ghostty.Surface) {
        self.surface = surface
    }

    @MainActor
    static func hub(for surface: Ghostty.Surface) -> RemoteTapHub {
        let key = ObjectIdentifier(surface)
        if let hub = hubs[key] { return hub }
        let hub = RemoteTapHub(surface: surface)
        hubs[key] = hub
        return hub
    }

    @MainActor
    func subscribe(_ mirror: RemoteMirror) {
        lock.lock()
        let first = subscribers.isEmpty
        subscribers.append(Subscriber(mirror: mirror, wantsSnapshot: true))
        lock.unlock()

        // Called with our lock released: the snapshot may come back during the call.
        if first {
            ghostty_surface_set_pty_tap(surface.unsafeCValue, remoteTapHubCallback, Unmanaged.passUnretained(self).toOpaque())
        } else {
            ghostty_surface_pty_tap_snapshot(surface.unsafeCValue)
        }
    }

    @MainActor
    func unsubscribe(_ mirror: RemoteMirror) {
        lock.lock()
        subscribers.removeAll { $0.mirror === mirror }
        let last = subscribers.isEmpty
        lock.unlock()

        guard last else { return }
        ghostty_surface_set_pty_tap(surface.unsafeCValue, nil, nil)
        Self.hubs[ObjectIdentifier(surface)] = nil
    }

    @MainActor
    func requestSnapshot(for mirror: RemoteMirror) {
        lock.lock()
        if let index = subscribers.firstIndex(where: { $0.mirror === mirror }) {
            subscribers[index].wantsSnapshot = true
        }
        lock.unlock()
        ghostty_surface_pty_tap_snapshot(surface.unsafeCValue)
    }

    /// From the tap, on any thread, with the terminal locked.
    fileprivate func received(_ event: ghostty_pty_tap_event_s) {
        let item: RemoteOutputBuffer.Item
        switch event.kind {
        case GHOSTTY_PTY_TAP_SNAPSHOT:
            item = .snapshot(columns: event.columns, rows: event.rows, vt: Self.copy(event))
        case GHOSTTY_PTY_TAP_OUTPUT:
            item = .output(Self.copy(event))
        case GHOSTTY_PTY_TAP_RESIZE:
            item = .resize(columns: event.columns, rows: event.rows)
        default:
            return
        }

        lock.lock()
        var receivers: [RemoteMirror] = []
        for index in subscribers.indices {
            if case .snapshot = item {
                guard subscribers[index].wantsSnapshot else { continue }
                subscribers[index].wantsSnapshot = false
            } else if subscribers[index].wantsSnapshot {
                continue
            }
            receivers.append(subscribers[index].mirror)
        }
        lock.unlock()

        receivers.forEach { $0.received(item) }
    }

    private static func copy(_ event: ghostty_pty_tap_event_s) -> Data {
        guard let bytes = event.bytes, event.len > 0 else { return Data() }
        return Data(bytes: bytes, count: Int(event.len))
    }
}

/// The C tap: forwards each event to its hub.
private func remoteTapHubCallback(_ userdata: UnsafeMutableRawPointer?, _ event: UnsafePointer<ghostty_pty_tap_event_s>?) {
    guard let userdata, let event else { return }
    Unmanaged<RemoteTapHub>.fromOpaque(userdata).takeUnretainedValue().received(event.pointee)
}

/// The sessions one device mirrors. Follows each session's focused split and notices
/// when its tab goes.
@MainActor
final class RemoteTerminalStreams {
    private let socket: RemoteSocket
    private let feed: RemoteSessionFeed
    private var mirrors: [String: RemoteMirror] = [:]
    private var nextStream: UInt32 = 1
    private var timer: Timer?

    /// Called when a mirrored session ends on the Mac.
    var onClosed: ((SessionClosed) -> Void)?

    init(socket: RemoteSocket, feed: RemoteSessionFeed) {
        self.socket = socket
        self.feed = feed
    }

    /// Starts mirroring a session, or resyncs one already mirrored.
    func open(sessionID: String) -> Result<SessionOpened, RemoteError> {
        guard let window = feed.ids.window(for: sessionID),
              let view = window.terminalController?.focusedSurface,
              let surface = view.surface else {
            return .failure(RemoteError(code: .notFound, message: "That session is no longer open on the Mac."))
        }

        let mirror = mirrors[sessionID] ?? {
            let mirror = RemoteMirror(stream: nextStream, sessionID: sessionID, socket: socket)
            nextStream &+= 1
            mirrors[sessionID] = mirror
            return mirror
        }()
        let size = ghostty_surface_size(surface)
        let opened = SessionOpened(id: sessionID, stream: mirror.stream, columns: size.columns, rows: size.rows)

        // The answer goes out before the tap's snapshot, which may come during attach.
        socket.send(.sessionOpened(opened))
        mirror.attach(view)
        startWatching()
        return .success(opened)
    }

    func leave(sessionID: String) {
        mirrors.removeValue(forKey: sessionID)?.detach()
        if mirrors.isEmpty { stopWatching() }
    }

    /// Sizes a mirrored session's terminal to the device's grid; false when it isn't
    /// mirrored.
    func fit(_ request: FitSession) -> Bool {
        guard let mirror = mirrors[request.id] else { return false }
        if let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 {
            let size = RemoteFit.Size(columns: max(columns, RemoteFit.minimum.columns), rows: max(rows, RemoteFit.minimum.rows))
            mirror.setFit(size, deviceName: deviceName)
        } else {
            mirror.setFit(nil, deviceName: deviceName)
        }
        return true
    }

    /// The device's name, once it said hello.
    var deviceName = "a device"

    func resync(sessionID: String) -> Bool {
        guard let mirror = mirrors[sessionID] else { return false }
        mirror.requestSnapshot()
        return true
    }

    /// An input frame from the device.
    func input(_ frame: RemoteFrame) {
        guard frame.kind == .input,
              let mirror = mirrors.values.first(where: { $0.stream == frame.stream }) else { return }
        mirror.write(frame.payload)
    }

    func closeAll() {
        mirrors.values.forEach { $0.detach() }
        mirrors = [:]
        stopWatching()
    }

    private func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    /// Follows focus to another split, and lets go of sessions whose tab or split closed.
    private func check() {
        for (id, mirror) in mirrors {
            guard let window = feed.ids.window(for: id),
                  let controller = window.terminalController,
                  let focused = controller.focusedSurface else {
                mirrors[id] = nil
                mirror.detach()
                onClosed?(SessionClosed(id: id, reason: .closed))
                continue
            }
            if focused !== mirror.surfaceView {
                mirror.attach(focused)
            }
        }
        if mirrors.isEmpty { stopWatching() }
    }
}

/// What asks `RemoteFit` for a grid: a device's mirror of one session.
protocol RemoteFitOwner: AnyObject {
    /// The terminal was used on the Mac, which took its size back.
    @MainActor func fitTakenBack()
}

/// The grids devices asked for, per terminal: a device that shows a session at a larger
/// text size asks for fewer columns and rows, so lines wrap at its edge. With several
/// devices on one terminal the smallest grid wins; when the last lets go, the terminal
/// fills its view again. Typing or clicking in the terminal on the Mac, or its Use Full
/// Window button, takes the size back from every device at once.
@MainActor
enum RemoteFit {
    struct Size: Equatable {
        var columns: UInt16
        var rows: UInt16
    }

    /// The smallest grid a device can ask for, so a slip of the fingers can't leave the
    /// Mac with an unusable terminal.
    static let minimum = Size(columns: 20, rows: 5)

    private struct Request {
        weak var owner: RemoteFitOwner?
        var size: Size
        var deviceName: String
    }

    private struct Entry {
        weak var view: Ghostty.SurfaceView?
        var requests: [ObjectIdentifier: Request]
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    private static let takeBackObserver = NotificationCenter.default.addObserver(
        forName: Ghostty.SurfaceView.didTakeBackFromDevice,
        object: nil,
        queue: .main
    ) { notification in
        guard let view = notification.object as? Ghostty.SurfaceView else { return }
        MainActor.assumeIsolated { takeBack(view) }
    }

    /// Sets or clears `owner`'s grid for `view`, and applies the smallest of them all.
    static func set(_ size: Size?, by owner: RemoteFitOwner, deviceName: String, on view: Ghostty.SurfaceView) {
        _ = takeBackObserver
        let key = ObjectIdentifier(view)
        var entry = entries[key] ?? Entry(view: view, requests: [:])
        entry.requests[ObjectIdentifier(owner)] = size.map { Request(owner: owner, size: $0, deviceName: deviceName) }
        entries[key] = entry.requests.isEmpty ? nil : entry
        entries = entries.filter { $0.value.view != nil }
        apply(entry, to: view)
    }

    /// The Mac uses `view` again: every device's grid for it goes, and each is told.
    static func takeBack(_ view: Ghostty.SurfaceView) {
        let owners = entries.removeValue(forKey: ObjectIdentifier(view))?.requests.values.compactMap(\.owner) ?? []
        view.deviceGrid = nil
        owners.forEach { $0.fitTakenBack() }
    }

    private static func apply(_ entry: Entry, to view: Ghostty.SurfaceView) {
        let requests = Array(entry.requests.values)
        guard let limit = smallest(requests.map(\.size)) else {
            view.deviceGrid = nil
            return
        }
        // Named after the device whose grid is the narrowest.
        let name = requests.min { $0.size.columns < $1.size.columns }?.deviceName ?? "a device"
        let grid = Ghostty.SurfaceView.DeviceGrid(columns: limit.columns, rows: limit.rows, deviceName: name)
        if view.deviceGrid != grid { view.deviceGrid = grid }
    }

    /// The grid that fits every one of `sizes`; none for none.
    static func smallest(_ sizes: [Size]) -> Size? {
        guard let first = sizes.first else { return nil }
        return sizes.dropFirst().reduce(first) {
            Size(columns: min($0.columns, $1.columns), rows: min($0.rows, $1.rows))
        }
    }
}
