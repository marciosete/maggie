import AppKit
import SwiftUI

/// The resource manager: the window's sessions, or every window's, with the memory and
/// CPU their terminals' processes use, grouped by sidebar folder, and Maggie's own.
/// Clicking a session goes to it; its ✕ closes it, asking first if anything in it is
/// still running.
struct ResourceManagerView: View {
    @ObservedObject var monitor: ResourceMonitor

    /// The window it was opened from.
    weak var window: TerminalWindow?
    let dismiss: () -> Void

    enum Scope {
        case window
        case all
    }

    @State private var scope: Scope = .window

    enum Sort {
        case memory
        case cpu
        case name
    }

    @State private var sort: Sort = .memory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            columns
                .padding(.horizontal, 12)
                .padding(.vertical, 5)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sessions.isEmpty {
                        Text("No sessions")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    ForEach(groups, id: \.name) { group in
                        ResourceFolderHeader(name: group.name, usage: group.usage)
                        ForEach(group.sessions) { session in
                            ResourceSessionRow(session: session, dismiss: dismiss)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: sessions.isEmpty ? 48 : min(360, CGFloat(rowCount) * 24 + 12))

            Divider()

            HStack(spacing: 0) {
                Image("MaggieGlyph")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .padding(.trailing, 6)
                Text("Maggie")
                Spacer()
                ResourceFigures(usage: monitor.app)
                Color.clear.frame(width: ResourceSessionRow.closeWidth)
            }
            .help("The app itself, with the helpers it runs outside any session")
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .font(.system(size: 12))
        .frame(width: 400)
        .onAppear { monitor.sample() }
    }

    /// Whether it lists every window's sessions: when asked to, or with only one window.
    private var showsAll: Bool { scope == .all || window == nil || !monitor.spansWindows }

    private var sessions: [ResourceSession] {
        showsAll ? monitor.sessions : monitor.sessions(inWindowOf: window)
    }

    /// The window's sessions, or every session and the app.
    private var total: ResourceUsage {
        showsAll ? monitor.total : sessions.map(\.usage).reduce(ResourceUsage(), +)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Resource Manager")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 8) {
                    Text("\(ResourceFormat.cpu(total.cpu)) CPU")
                        .help(showsAll
                            ? "CPU of every session and the app, in percent of one core"
                            : "CPU of this window's sessions, in percent of one core")
                    Text("·").foregroundStyle(.tertiary)
                    Text(ResourceFormat.memory(total.memory))
                        .help(showsAll
                            ? "Memory of every session and the app, as Activity Monitor counts it"
                            : "Memory of this window's sessions, as Activity Monitor counts it")
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            // Only with sessions in more than one window is there a choice to make.
            if window != nil && monitor.spansWindows {
                Picker("Sessions", selection: $scope) {
                    Text("This Window").tag(Scope.window)
                    Text("All Windows").tag(Scope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            column("Name", .name)
            Spacer()
            column("CPU", .cpu)
                .frame(width: ResourceFigures.cpuWidth, alignment: .trailing)
            column("Memory", .memory)
                .frame(width: ResourceFigures.memoryWidth, alignment: .trailing)
            Color.clear.frame(width: ResourceSessionRow.closeWidth)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    }

    private func column(_ title: String, _ sort: Sort) -> some View {
        Button {
            self.sort = sort
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if self.sort == sort {
                    Image(systemName: sort == .name ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private struct Group {
        let name: String
        let sessions: [ResourceSession]
        var usage: ResourceUsage { sessions.map(\.usage).reduce(ResourceUsage(), +) }
    }

    /// Folders by what they use, with the sessions in no folder last.
    private var groups: [Group] {
        let byFolder = Dictionary(grouping: sessions) { $0.folder }
        var groups = byFolder.compactMap { folder, sessions -> Group? in
            guard let folder else { return nil }
            return Group(name: folder, sessions: sorted(sessions))
        }
        groups.sort { order($0.usage, $0.name, $1.usage, $1.name) }
        if let loose = byFolder[nil] {
            groups.append(Group(name: groups.isEmpty ? "Sessions" : "Other Sessions", sessions: sorted(loose)))
        }
        return groups
    }

    private var rowCount: Int {
        groups.reduce(0) { $0 + 1 + $1.sessions.count }
    }

    private func sorted(_ sessions: [ResourceSession]) -> [ResourceSession] {
        sessions.sorted { order($0.usage, $0.title, $1.usage, $1.title) }
    }

    private func order(_ lhs: ResourceUsage, _ lhsName: String, _ rhs: ResourceUsage, _ rhsName: String) -> Bool {
        switch sort {
        case .memory: return lhs.memory != rhs.memory ? lhs.memory > rhs.memory : lhsName < rhsName
        case .cpu: return lhs.cpu != rhs.cpu ? lhs.cpu > rhs.cpu : lhsName < rhsName
        case .name: return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
        }
    }
}

private struct ResourceFolderHeader: View {
    let name: String
    let usage: ResourceUsage

    var body: some View {
        HStack(spacing: 0) {
            Text(name.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            ResourceFigures(usage: usage)
                .foregroundStyle(.tertiary)
            Color.clear.frame(width: ResourceSessionRow.closeWidth)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .frame(height: 24)
    }
}

private struct ResourceSessionRow: View {
    let session: ResourceSession
    let dismiss: () -> Void

    static let closeWidth: CGFloat = 22

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(session.usage.cpu >= 1 ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .padding(.trailing, 7)
                .help(session.usage.cpu >= 1 ? "Busy" : "Idle")
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            ResourceFigures(usage: session.usage)
            Button {
                guard let window = session.window else { return }
                dismiss()
                window.tabSidebarModel.close(window)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .frame(width: Self.closeWidth, alignment: .trailing)
            .help("Close Session")
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(isHovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard let window = session.window else { return }
            window.tabSidebarModel.select(window)
        }
        .help("\(session.title)\n\(session.processCount) processes · Click to go to it")
    }
}

/// CPU and memory, in fixed columns so rows line up.
private struct ResourceFigures: View {
    let usage: ResourceUsage

    static let cpuWidth: CGFloat = 52
    static let memoryWidth: CGFloat = 78

    var body: some View {
        HStack(spacing: 0) {
            Text(ResourceFormat.cpu(usage.cpu))
                .frame(width: Self.cpuWidth, alignment: .trailing)
            Text(ResourceFormat.memory(usage.memory))
                .frame(width: Self.memoryWidth, alignment: .trailing)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}
