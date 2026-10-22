import AppKit
import Combine

/// The session board as the device sees it, laid out as the Mac's board lays it out:
/// work items, then the sessions not linked to one, in each column's order; and every
/// session on its own, as the sessions view shows them, with the view the Mac shows.
enum RemoteBoard {
    static func snapshot(
        tabs: [TabSidebarModel.Tab],
        items: [WorkItem],
        settings: SessionBoardSettings,
        id: (TabSidebarModel.Tab) -> String
    ) -> BoardSnapshot {
        let columns = settings.columns.map {
            BoardColumn(id: $0.id, label: $0.label, color: TabColorName($0.color), icon: $0.icon)
        }
        let itemIDs = Set(items.map(\.id))
        var linked: [UUID: [TabSidebarModel.Tab]] = [:]
        for tab in tabs {
            if let item = tab.workItemID, itemIDs.contains(item) { linked[item, default: []].append(tab) }
        }
        let loose = tabs.filter { !($0.workItemID.map(itemIDs.contains) ?? false) }

        let itemLanes = SessionBoardLayout.lanes(items.map { .init(id: $0.id, place: $0.place) }, settings: settings)
        let sessionLanes = SessionBoardLayout.lanes(loose.map { .init(id: $0.id, place: $0.boardPlace) }, settings: settings)
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let tabsByID = Dictionary(uniqueKeysWithValues: loose.map { ($0.id, $0) })

        let allTabs = Dictionary(tabs.map { ($0.id, $0) }) { first, _ in first }
        let allLanes = SessionBoardLayout.lanes(tabs.map { .init(id: $0.id, place: $0.boardPlace) }, settings: settings)
        let sessions = settings.columns.flatMap { column in
            (allLanes[column.id] ?? []).compactMap { allTabs[$0] }.map { tab in
                session(tab, column: column.id, settings: settings, id: id, workItemID: tab.workItemID.flatMap { itemIDs.contains($0) ? $0.uuidString : nil })
            }
        }

        var cards: [BoardCard] = []
        for column in settings.columns {
            for itemID in itemLanes[column.id] ?? [] {
                guard let item = itemsByID[itemID] else { continue }
                cards.append(BoardCard(
                    kind: .workItem,
                    id: item.id.uuidString,
                    title: item.title,
                    column: column.id,
                    color: TabColorName(item.color),
                    colorLabel: settings.label(of: item.color),
                    sessionIDs: (linked[item.id] ?? []).map(id)))
            }
            for tabID in sessionLanes[column.id] ?? [] {
                guard let tab = tabsByID[tabID] else { continue }
                cards.append(session(tab, column: column.id, settings: settings, id: id, workItemID: nil))
            }
        }
        return BoardSnapshot(columns: columns, cards: cards, mode: BoardMode(rawValue: settings.mode.rawValue), sessions: sessions)
    }

    private static func session(
        _ tab: TabSidebarModel.Tab,
        column: String,
        settings: SessionBoardSettings,
        id: (TabSidebarModel.Tab) -> String,
        workItemID: String?
    ) -> BoardCard {
        BoardCard(
            kind: .session,
            id: id(tab),
            title: tab.title,
            column: column,
            color: TabColorName(tab.assignedColor),
            colorLabel: settings.label(of: tab.assignedColor),
            light: tab.claudeCodeState.map { SessionLight($0.light) },
            workItemID: workItemID)
    }

    /// The work items on the board of the window `id` names, or all of them when it names
    /// none or one the Mac no longer has.
    @MainActor
    static func items(_ items: [WorkItem], window id: String?) -> [WorkItem] {
        guard let uuid = id.flatMap(UUID.init(uuidString:)), RemoteCommands.window(id: uuid.uuidString) != nil else { return items }
        return TabSidebarModel.boardItems(items, window: uuid)
    }

    /// Moves a card to the end of `column`, as dropping it there on the Mac's board does.
    @MainActor
    static func move(_ request: MoveCard, tabs: [TabSidebarModel.Tab], feed: RemoteSessionFeed) -> Bool {
        let settings = SessionBoardSettings.shared
        guard settings.columns.contains(where: { $0.id == request.column }) else { return false }
        switch request.kind {
        case .workItem:
            guard let uuid = UUID(uuidString: request.id), WorkItemStore.shared.items.contains(where: { $0.id == uuid }) else { return false }
            WorkItemStore.shared.move(uuid, to: request.column, before: nil, settings: settings)
            return true
        case .session:
            guard let window = feed.ids.window(for: request.id) else { return false }
            let lanes = SessionBoardLayout.lanes(tabs.map { .init(id: $0.id, place: $0.boardPlace) }, settings: settings)
            let places = SessionBoardLayout.move(ObjectIdentifier(window), to: request.column, before: nil, lanes: lanes)
            for tab in tabs {
                if let place = places[tab.id] { tab.window?.boardPlace = place }
            }
            return true
        }
    }
}

/// The usage panel's figures, for the device's usage sheet.
enum RemoteUsage {
    static func report(_ summary: UsageSummary, rangeLabel: String) -> RemoteUsageReport {
        let latest = summary.periods.last
        return RemoteUsageReport(
            rangeLabel: rangeLabel,
            costUsd: summary.costUsd,
            tokens: summary.totals.total,
            sessions: summary.sessions,
            latestCostUsd: latest?.costUsd ?? 0,
            latestTokens: latest?.totalTokens ?? 0,
            models: summary.models.prefix(8).map {
                RemoteUsageReport.Model(provider: $0.provider.rawValue, model: $0.model, costUsd: $0.isCostUnknown ? nil : $0.costUsd, tokens: $0.totalTokens)
            })
    }

    /// The panel's summary, scanning first if it has none yet.
    @MainActor
    static func current() async -> RemoteUsageReport? {
        let model = UsagePanelModel.shared
        if model.summary == nil {
            model.refresh()
            // A first scan reads every transcript and can take a while.
            for _ in 0..<600 where model.summary == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let summary = model.summary else { return nil }
        return report(summary, rangeLabel: UsageSettings.shared.range.label)
    }
}

/// A session's last lines, for a preview on the device.
enum RemotePeek {
    static let lineCount = 20

    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { line in
            String(line.reversed().drop(while: { $0 == " " }).reversed())
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return Array(lines.suffix(lineCount))
    }

    @MainActor
    static func peek(sessionID: String, feed: RemoteSessionFeed) -> SessionPeek? {
        guard let view = feed.ids.window(for: sessionID)?.terminalController?.focusedSurface else { return nil }
        return SessionPeek(id: sessionID, lines: lines(of: view.cachedVisibleContents.get()))
    }
}
