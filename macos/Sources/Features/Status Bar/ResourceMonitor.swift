import AppKit
import Darwin

/// How much memory and CPU something uses.
struct ResourceUsage: Equatable {
    /// The physical footprint, as Activity Monitor's Memory column shows it, in bytes.
    var memory: UInt64 = 0

    /// Percent of one core; a busy tree can pass 100.
    var cpu: Double = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(memory: lhs.memory + rhs.memory, cpu: lhs.cpu + rhs.cpu)
    }
}

/// A session, a tab of the sidebar, with what all of its terminals' processes use.
struct ResourceSession: Identifiable, Equatable {
    let id: ObjectIdentifier
    weak var window: TerminalWindow?
    let title: String

    /// The sidebar folder it is in.
    let folder: String?

    /// The window it is a tab of (see `ResourceMonitor.windowKey`).
    let windowKey: ObjectIdentifier
    var usage: ResourceUsage
    var processCount: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.folder == rhs.folder && lhs.windowKey == rhs.windowKey
            && lhs.usage == rhs.usage && lhs.processCount == rhs.processCount
    }
}

/// Measures every session's processes and the app's own, for the status bar's resource
/// manager. It samples while any status bar shows it, every few seconds; a sample takes
/// one look at the process table, so it stays cheap.
@MainActor
final class ResourceMonitor: ObservableObject {
    static let shared = ResourceMonitor()

    private static let interval: TimeInterval = 3

    @Published private(set) var sessions: [ResourceSession] = []

    /// Maggie itself, with the processes it runs that belong to no session.
    @Published private(set) var app = ResourceUsage()

    @Published private(set) var hasSampled = false

    var total: ResourceUsage { sessions.map(\.usage).reduce(app, +) }

    /// The sessions of the window `window` is a tab of, which its status bar counts; all
    /// of them without a window. None until the window has been sampled.
    ///
    /// The window's key is the one read when it was sampled, not read now: this runs in
    /// the status bar's view body, and reading `tabGroup` there on a window that has no
    /// tab group yet makes AppKit build one, in the middle of SwiftUI's update. The
    /// bar's views come out of that no longer told of the monitor's changes, so the
    /// first window's bar kept showing its first sample until the bar was made again.
    func sessions(inWindowOf window: TerminalWindow?) -> [ResourceSession] {
        guard let window else { return sessions }
        let id = ObjectIdentifier(window)
        guard let key = sessions.first(where: { $0.id == id })?.windowKey else { return [] }
        return sessions.filter { $0.windowKey == key }
    }

    /// Whether the sessions are in more than one window.
    var spansWindows: Bool {
        guard let first = sessions.first?.windowKey else { return false }
        return sessions.contains { $0.windowKey != first }
    }

    /// What tells the window a tab is in: its native tab group, or the tab itself when it
    /// has none.
    static func windowKey(of window: TerminalWindow) -> ObjectIdentifier {
        window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
    }

    private var users = 0
    private var timer: Timer?
    private var isSampling = false
    private let sampler = ResourceSampler()

    private init() {}

    /// Starts sampling for one more status bar; `stop` when it goes.
    func start() {
        users += 1
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func sample() {
        guard !isSampling else { return }
        isSampling = true

        // The terminals are read here; the processes off the main thread.
        let folders = UserTabFolderStore.shared.folders
        let windows = Self.sessionWindows()
        let terminals = windows.map { window in
            ResourceSampler.Terminals(
                id: ObjectIdentifier(window),
                pids: (window.terminalController?.surfaceTree.root?.leaves() ?? [])
                    .compactMap { $0.surfaceModel?.foregroundPID }
                    .map { pid_t($0) })
        }
        let sampler = sampler
        DispatchQueue.global(qos: .utility).async {
            let result = sampler.sample(terminals)
            DispatchQueue.main.async {
                self.isSampling = false
                self.show(result, windows: windows, folders: folders)
            }
        }
    }

    /// The sessions the sidebars list: the terminal windows on the screen or in the Dock,
    /// with the tabs behind them. The app's window list can also hold windows no longer
    /// shown, such as ones being closed, which aren't sessions.
    static func sessionWindows() -> [TerminalWindow] {
        NSApp.windows.compactMap { $0 as? TerminalWindow }.filter { window in
            guard let controller = window.terminalController, !controller.surfaceTree.isEmpty else { return false }
            let front = window.tabGroup?.selectedWindow ?? window
            let isShown = front.isVisible || front.isMiniaturized
            return isShown && (window === front || window.tabGroup?.windows.contains(window) == true)
        }
    }

    private func show(_ result: ResourceSampler.Result, windows: [TerminalWindow], folders: [UUID: UserTabFolder]) {
        let sessions = windows.map { window -> ResourceSession in
            let id = ObjectIdentifier(window)
            let measured = result.sessions[id]
            return ResourceSession(
                id: id,
                window: window,
                title: window.title.isEmpty ? "Session" : window.title,
                folder: window.userTabFolderID.flatMap { folders[$0]?.name },
                windowKey: Self.windowKey(of: window),
                usage: measured?.usage ?? ResourceUsage(),
                processCount: measured?.processCount ?? 0)
        }
        if self.sessions != sessions { self.sessions = sessions }
        if app != result.app { app = result.app }
        hasSampled = true
    }
}

/// Reads the process table. Kept apart from the monitor so it runs off the main thread,
/// one sample at a time.
final class ResourceSampler: @unchecked Sendable {
    struct Terminals {
        let id: ObjectIdentifier

        /// The foreground process of each of its terminals.
        let pids: [pid_t]
    }

    struct Result {
        var sessions: [ObjectIdentifier: (usage: ResourceUsage, processCount: Int)] = [:]
        var app = ResourceUsage()
    }

    /// Each process's CPU time at the last sample, to tell how busy it has been since.
    private var lastCPUTime: [pid_t: UInt64] = [:]
    private var lastSampleAt: UInt64 = 0

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func sample(_ terminals: [Terminals]) -> Result {
        let app = getpid()
        let parents = Self.parents()
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents { children[parent, default: []].append(pid) }

        let now = mach_absolute_time()
        let elapsed = Self.nanoseconds(now &- lastSampleAt)
        var cpuTimes: [pid_t: UInt64] = [:]

        func usage(of pids: [pid_t]) -> ResourceUsage {
            var total = ResourceUsage()
            for pid in pids {
                guard let measured = Self.rusage(pid) else { continue }
                total.memory += measured.footprint
                cpuTimes[pid] = measured.cpuTime
                if lastSampleAt > 0, elapsed > 0, let before = lastCPUTime[pid], measured.cpuTime >= before {
                    total.cpu += Double(measured.cpuTime - before) / Double(elapsed) * 100
                }
            }
            return total
        }

        // A terminal's processes hang from the one the app started for it, so each
        // foreground process is followed up to the app's child, and that one's tree is
        // the terminal's.
        var claimed: Set<pid_t> = []
        var result = Result()
        for terminal in terminals {
            var pids: [pid_t] = []
            for pid in terminal.pids {
                guard let root = Self.root(of: pid, under: app, parents: parents), !claimed.contains(root) else { continue }
                let tree = Self.tree(from: root, children: children).filter { !claimed.contains($0) }
                claimed.formUnion(tree)
                pids += tree
            }
            result.sessions[terminal.id] = (usage(of: pids), pids.count)
        }

        let own = Self.tree(from: app, children: children).filter { !claimed.contains($0) }
        result.app = usage(of: own)

        lastCPUTime = cpuTimes
        lastSampleAt = now
        return result
    }

    /// The ancestor of `pid` whose parent is `app`.
    static func root(of pid: pid_t, under app: pid_t, parents: [pid_t: pid_t]) -> pid_t? {
        var current = pid
        var steps = 0
        while let parent = parents[current], steps < 64 {
            if parent == app { return current }
            if parent <= 1 { return nil }
            current = parent
            steps += 1
        }
        return nil
    }

    static func tree(from root: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        var tree: [pid_t] = []
        var queue = [root]
        var seen: Set<pid_t> = []
        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted else { continue }
            tree.append(pid)
            queue += children[pid] ?? []
        }
        return tree
    }

    /// Every process's parent, from one read of the process table.
    static func parents() -> [pid_t: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // The table can grow between the two calls.
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var parents: [pid_t: pid_t] = [:]
        parents.reserveCapacity(count)
        for proc in procs.prefix(count) {
            parents[proc.kp_proc.p_pid] = proc.kp_eproc.e_ppid
        }
        return parents
    }

    private static func rusage(_ pid: pid_t) -> (footprint: UInt64, cpuTime: UInt64)? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        return (info.ri_phys_footprint, nanoseconds(info.ri_user_time + info.ri_system_time))
    }

    /// CPU times come in Mach ticks, which are nanoseconds only on Intel.
    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks / UInt64(timebase.denom) * UInt64(timebase.numer)
    }
}

enum ResourceFormat {
    static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1 { return "\(bytes / 1024) KB" }
        if megabytes < 1024 { return String(format: "%.1f MB", megabytes) }
        return String(format: "%.2f GB", megabytes / 1024)
    }

    static func cpu(_ percent: Double) -> String {
        percent < 10 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }
}
