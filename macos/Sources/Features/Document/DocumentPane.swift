import AppKit
import SwiftUI

/// The width of the document pane, shared by every window and kept across launches.
final class DocumentPaneSettings: ObservableObject {
    static let shared = DocumentPaneSettings()

    private static let widthKey = "DocumentPaneWidth"

    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 1200
    static let defaultWidth: CGFloat = 560

    @Published var width: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(width), forKey: Self.widthKey) }
    }

    private init() {
        let storedWidth = UserDefaults.ghostty.double(forKey: Self.widthKey)
        width = storedWidth > 0 ? Self.clampWidth(CGFloat(storedWidth)) : Self.defaultWidth
    }

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}

/// The document pane of one session's window: the Markdown file shown beside the
/// terminal, if any, read or being edited. A ⌘-clicked path in the session's output
/// lands here.
@MainActor
final class DocumentPaneModel: ObservableObject {
    @Published private(set) var file: URL?
    @Published var isEditing = false

    var isVisible: Bool { file != nil }

    func show(_ file: URL) {
        let standardized = file.standardizedFileURL
        if standardized != self.file { isEditing = false }
        self.file = standardized
    }

    func close() {
        file = nil
        isEditing = false
    }

    /// Moves the document into a window of its own and closes the pane.
    func popOut() {
        guard let file else { return }
        close()
        DocumentViewerController.show(file)
    }
}

/// The document pane: a header naming the file, with its tools, over the document,
/// rendered or as text to edit. It sits to the right of the terminal, like the
/// source control panel.
struct DocumentPaneView: View {
    @ObservedObject var model: DocumentPaneModel
    @ObservedObject var settings = DocumentPaneSettings.shared

    /// Space to leave at the top when the pane extends under the titlebar.
    let topInset: CGFloat

    @State private var resizeStartWidth: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: topInset)
            if let file = model.file {
                header(file)
                Divider()
                if model.isEditing {
                    DocumentEditorRepresentable(file: file)
                        .id(file)
                } else {
                    DocumentWebRepresentable(file: file) { model.show($0) }
                }
            }
        }
        .background(TabSidebarVisualEffectBackground())
        .overlay(alignment: .leading) { resizeHandle }
    }

    private func header(_ file: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(file.path)

            Spacer(minLength: 8)

            if model.isEditing {
                PaneHeaderButton(symbol: "checkmark", help: "Done Editing", prominent: true) {
                    model.isEditing = false
                }
            } else {
                PaneHeaderButton(symbol: "pencil", help: "Edit") { model.isEditing = true }
            }
            PaneHeaderButton(symbol: "arrow.up.forward.app", help: "Open in Default App") {
                DocumentWebView.openInEditor(file)
            }
            PaneHeaderButton(symbol: "macwindow.badge.plus", help: "Open in a Window") { model.popOut() }
            PaneHeaderButton(symbol: "xmark", help: "Close Document") { model.close() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // The handle is on the left, so dragging left widens the pane.
                        let start = resizeStartWidth ?? settings.width
                        resizeStartWidth = start
                        settings.width = DocumentPaneSettings.clampWidth(start - value.translation.width)
                    }
                    .onEnded { _ in resizeStartWidth = nil }
            )
    }
}

/// A tool in the pane's header: a symbol that lights up under the pointer and
/// says what it does in a tooltip.
struct PaneHeaderButton: View {
    let symbol: String
    let help: String
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(hovering ? .primary : .secondary))
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
