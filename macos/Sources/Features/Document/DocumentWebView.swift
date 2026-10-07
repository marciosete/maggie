import AppKit
import SwiftUI
import WebKit

/// A Markdown file rendered in a web view. It rereads the file as it changes, so a
/// document an agent is still writing keeps up, and follows the links in it: another
/// Markdown file opens where this one is shown, the web opens in the browser.
@MainActor
final class DocumentWebView: NSView, WKNavigationDelegate {
    /// Called with a Markdown file a link in the document points at.
    var onOpenDocument: ((URL) -> Void)?

    private(set) var file: URL
    private let webView: WKWebView
    private var watcher: FileChangeWatcher?
    /// Where the page was scrolled before a reload, to go back to once it loads.
    private var scrollToRestore: Double?

    init(file: URL) {
        self.file = file

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false

        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        watch()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `file` instead, from the top.
    func show(_ file: URL) {
        guard file != self.file else { return }
        self.file = file
        scrollToRestore = nil
        watch()
        load()
    }

    private func watch() {
        watcher = FileChangeWatcher(path: file.path) { [weak self] in self?.reload() }
    }

    private var html: String {
        guard let data = try? Data(contentsOf: file) else {
            let message = "\(file.lastPathComponent) can't be read. It may have been moved or deleted."
            return MarkdownHTML.page(markdown: "_\(message)_", title: file.lastPathComponent, baseDirectory: nil)
        }
        return MarkdownHTML.page(
            markdown: String(decoding: data, as: UTF8.self),
            title: file.lastPathComponent,
            baseDirectory: file.deletingLastPathComponent())
    }

    private func load() {
        webView.loadHTMLString(html, baseURL: file.deletingLastPathComponent())
    }

    /// Reloads the file where the page was, so an edit doesn't jump the reader back
    /// to the top.
    func reload() {
        webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
            guard let self else { return }
            self.scrollToRestore = value as? Double
            self.load()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let y = scrollToRestore else { return }
        scrollToRestore = nil
        webView.evaluateJavaScript("window.scrollTo(0, \(y))")
    }

    // MARK: - Links in the document

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // A link to a heading of this page stays on it.
        if url.fragment != nil, Self.withoutFragment(url) == Self.withoutFragment(file.deletingLastPathComponent()) {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
        follow(url)
    }

    /// Opens `url` from the document: another Markdown file where this one shows,
    /// anything else with the app for it.
    private func follow(_ url: URL) {
        if url.isFileURL {
            if DocumentLink.isMarkdown(url), FileManager.default.fileExists(atPath: url.path) {
                if let onOpenDocument {
                    onOpenDocument(url)
                } else {
                    show(url)
                }
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url?.standardizedFileURL.path ?? url.path
    }

    // MARK: - Editor

    /// Opens `file` the way Ghostty opens a text file: with the app for its extension,
    /// else the system text editor.
    static func openInEditor(_ file: URL) {
        let workspace = NSWorkspace.shared
        guard let editor = workspace.defaultApplicationURL(forExtension: file.pathExtension) ?? workspace.defaultTextEditor else {
            workspace.open(file)
            return
        }
        workspace.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// `DocumentWebView` for SwiftUI.
struct DocumentWebRepresentable: NSViewRepresentable {
    let file: URL
    var onOpenDocument: ((URL) -> Void)?

    func makeNSView(context: Context) -> DocumentWebView {
        let view = DocumentWebView(file: file)
        view.onOpenDocument = onOpenDocument
        return view
    }

    func updateNSView(_ view: DocumentWebView, context: Context) {
        view.onOpenDocument = onOpenDocument
        view.show(file)
    }
}

/// Calls back on the main queue when the file at `path` is written, replaced or
/// removed. Editors and agents save by writing a new file over the old one, so
/// after a rename or delete the path is watched again once it is back.
final class FileChangeWatcher {
    private let path: String
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
        watch()
    }

    deinit {
        source?.cancel()
        pending?.cancel()
    }

    private func watch() {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            retry()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                source.cancel()
                self.source = nil
                self.retry()
            }
            self.changed()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// Watches again shortly, for the file that replaced the one that went.
    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.source == nil else { return }
            self.watch()
        }
    }

    /// Reports a change once the burst of events a save makes has passed.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
