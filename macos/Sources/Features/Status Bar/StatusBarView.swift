import AppKit
import SwiftUI

/// The thin bar along the bottom of a window, under the sidebar and the terminal: the
/// Claude and Codex plan limits on the left, keeping the Mac awake and the resource
/// manager on the right. Right-clicking it picks what it shows.
struct StatusBarView: View {
    @ObservedObject var settings = StatusBarSettings.shared
    @ObservedObject private var usage = UsagePanelModel.shared

    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 14) {
            if settings.shows(.claudeUsage), let limits = usage.limits, limits.isShown {
                StatusBarLimits(
                    provider: .claude,
                    windows: limits.windows.map { window in
                        .init(
                            label: window.label,
                            usedPercent: window.usedPercent,
                            resetsAt: window.resetsAt,
                            namesModel: window.kind == .weeklyScoped)
                    },
                    failed: limits.unavailable == .failed,
                    help: limits.help)
            } else if settings.shows(.claudeUsage), usage.limits == nil {
                StatusBarLimitsLoading(provider: .claude)
            }

            if settings.shows(.codexUsage), let limits = usage.codexLimits, limits.isShown {
                StatusBarLimits(
                    provider: .codex,
                    windows: limits.windows.map { window in
                        .init(label: window.label, usedPercent: window.usedPercent, resetsAt: window.resetsAt, namesModel: false)
                    },
                    failed: limits.unavailable == .failed,
                    help: limits.help)
            }

            if settings.shows(.claudeUsage) || settings.shows(.codexUsage) {
                StatusBarRefreshButton(usage: usage)
            }

            Spacer(minLength: 8)

            if settings.shows(.caffeine) {
                CaffeineButton(showsState: true)
            }

            if settings.shows(.resources) {
                StatusBarResourcesButton()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        ForEach(StatusBarSettings.Item.allCases, id: \.self) { item in
            Toggle(item.localizedName, isOn: Binding(
                get: { settings.shows(item) },
                set: { _ in settings.toggle(item) }))
        }
        Divider()
        Button("Hide Status Bar") { settings.isVisible = false }
    }
}

// MARK: - Usage

/// One provider's plan windows: its logo, a bar for the window nearest its limit, and
/// each window's use with the time until it resets, or the model it is for. Clicking it
/// opens the usage panel.
private struct StatusBarLimits: View {
    struct Window: Equatable {
        let label: String
        let usedPercent: Double
        let resetsAt: Date?

        /// A window for one model, such as Fable, shows the model's name.
        let namesModel: Bool
    }

    let provider: UsageProvider
    let windows: [Window]
    let failed: Bool
    let help: String

    var body: some View {
        Button {
            NSApp.sendAction(#selector(TerminalController.toggleUsage(_:)), to: nil, from: nil)
        } label: {
            HStack(spacing: 5) {
                UsageProviderMark(provider: provider)
                    .frame(width: 12, height: 12)
                if let tightest = windows.map(\.usedPercent).max() {
                    UsageLimitBar(fraction: tightest / 100, color: Color.secondary.opacity(0.6))
                        .frame(width: 36)
                }
                if failed && windows.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: 4) {
                        ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                            if index > 0 { Text("·").foregroundStyle(.tertiary) }
                            text(window, at: context.date)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func text(_ window: Window, at now: Date) -> some View {
        let percent = Int(window.usedPercent.rounded())
        let detail = window.namesModel ? window.label : window.resetsAt.map { StatusBarFormat.reset($0, at: now) }
        return HStack(spacing: 3) {
            Text("\(percent)%")
                .foregroundStyle(StatusBarFormat.color(percent: window.usedPercent))
            if let detail {
                Text(detail)
            }
        }
        .monospacedDigit()
    }
}

/// A provider not read yet.
private struct StatusBarLimitsLoading: View {
    let provider: UsageProvider

    var body: some View {
        HStack(spacing: 5) {
            UsageProviderMark(provider: provider)
                .frame(width: 12, height: 12)
            Text("···")
                .foregroundStyle(.tertiary)
        }
    }
}

/// Reads the limits again now, whenever they were last read. It spins while they are.
/// It shows whenever a provider does, so it keeps the limits fresh while it shows.
private struct StatusBarRefreshButton: View {
    @ObservedObject var usage: UsagePanelModel

    var body: some View {
        Button {
            usage.refreshLimits(force: true)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .rotationEffect(.degrees(usage.isReadingLimits ? 360 : 0))
                .animation(
                    usage.isReadingLimits ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                    value: usage.isReadingLimits)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(usage.isReadingLimits)
        .help("Refresh usage")
        .onAppear { usage.startShowingLimits() }
        .onDisappear { usage.stopShowingLimits() }
    }
}

enum StatusBarFormat {
    /// The time until a window resets, as `47m`, `3h 54m` or `6d 7h`.
    static func reset(_ date: Date, at now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// Yellow from 60% of a limit, red from 80%.
    static func color(percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 60 { return .yellow }
        return .secondary
    }
}

extension ClaudeLimits {
    /// Whether the bar shows Claude at all: not when there's no CLI or no plan.
    fileprivate var isShown: Bool {
        !windows.isEmpty || unavailable == .failed
    }

    fileprivate var help: String {
        var lines = [account.map { [$0.label, $0.planLabel].compactMap { $0 }.joined(separator: " · ") } ?? "Claude"]
        if windows.isEmpty, unavailable == .failed { lines.append("Claude Code didn't report plan limits.") }
        for window in windows {
            var line = "\(window.label): \(Int(window.usedPercent.rounded()))% used"
            if let resetsAt = window.resetsAt { line += ", " + UsageFormat.reset(resetsAt) }
            lines.append(line)
        }
        lines.append("Click to show usage")
        return lines.joined(separator: "\n")
    }
}

extension CodexLimits {
    fileprivate var isShown: Bool {
        !windows.isEmpty || unavailable == .failed
    }

    fileprivate var help: String {
        var lines = [[accountLabel ?? "Codex", planLabel].compactMap { $0 }.joined(separator: " · ")]
        if windows.isEmpty, unavailable == .failed { lines.append("Codex didn't report plan limits.") }
        for window in windows {
            var line = "\(window.label): \(Int(window.usedPercent.rounded()))% used"
            if let resetsAt = window.resetsAt { line += ", " + UsageFormat.reset(resetsAt) }
            lines.append(line)
        }
        lines.append("Click to show usage")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Resources

/// The memory every session and the app use, and how many sessions there are. Clicking
/// it lists them.
private struct StatusBarResourcesButton: View {
    @ObservedObject private var monitor = ResourceMonitor.shared
    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10))
                Text(monitor.hasSampled ? ResourceFormat.memory(monitor.total.memory) : "–")
                    .monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "apple.terminal")
                    .font(.system(size: 10))
                Text("\(monitor.sessions.count)")
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Resource Manager\n\(ResourceFormat.memory(monitor.total.memory)) used by Maggie and its sessions\n\(monitor.sessions.count) sessions")
        .popover(isPresented: $isShowingPopover, arrowEdge: .top) {
            ResourceManagerView(monitor: monitor) { isShowingPopover = false }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}
