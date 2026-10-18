import AppKit
import Combine
import Sparkle
import SwiftUI

/// Holds Maggie closed until an update the feed marks critical is installed.
///
/// The release workflow puts the oldest build that may keep running in the appcast
/// (`fork/minimum-version`). At launch the updater asks the feed what it has, without
/// showing anything; when the answer is critical for this build, the terminal windows
/// stay closed and one window offers the update, with no way to skip it. Quitting stays
/// possible.
///
/// The build the feed named is remembered, so a build already known to be too old is
/// held the moment it launches, before the feed answers and without a network. Updating
/// clears it: the new build is at or above the floor.
///
/// Only a build with this code can be held. The first release that carries it is the
/// oldest one that can be made to update.
final class MandatoryUpdate: ObservableObject {
    static let defaultsKey = "MandatoryUpdateBuild"

    /// The update that is required, once the feed has said which. Nil while held from
    /// memory alone.
    @Published private(set) var required: SUAppcastItem?

    /// True while Maggie is held: the window is up, and nothing else opens.
    private(set) var isHolding = false

    /// Runs once the hold is lifted, so what the hold put off can happen: the first
    /// windows, at launch.
    var onLift: (() -> Void)?

    private let controller: UpdateController
    private let defaults: UserDefaults
    private let build: Int?
    private var window: MandatoryUpdateWindow?
    private var isModal = false
    private var installWhenFound = false
    private var cancellables: Set<AnyCancellable> = []

    init(controller: UpdateController,
         defaults: UserDefaults = .ghostty,
         build: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String) {
        self.controller = controller
        self.defaults = defaults
        self.build = build.flatMap(Int.init)

        // Once the person has asked to update, the update found is installed without
        // asking again. The state changes before @Published publishes it, so act on the
        // next turn.
        controller.viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.isHolding, self.installWhenFound else { return }
                if case .updateAvailable = state {
                    self.controller.viewModel.state.confirm()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Deciding

    /// The build the feed's critical marker names: everything below it must update.
    /// `fallback` is the update's own build, which is at or above the marker's; it
    /// stands in when the marker names none.
    static func minimumBuild(in properties: [AnyHashable: Any], fallback: String) -> Int? {
        if let marker = properties["sparkle:criticalUpdate"] as? [AnyHashable: Any],
           let version = marker["sparkle:version"] as? String,
           let build = Int(version) {
            return build
        }
        return Int(fallback)
    }

    /// Whether build `build` is below `minimumBuild`. A build that can't be read is
    /// never held: there is nothing to compare, and holding would be guessing.
    static func isHeld(minimumBuild: Int?, build: Int?) -> Bool {
        guard let minimumBuild, let build else { return false }
        return build < minimumBuild
    }

    /// The build remembered from the feed's last answer.
    var rememberedMinimumBuild: Int? {
        let build = defaults.integer(forKey: Self.defaultsKey)
        return build > 0 ? build : nil
    }

    // MARK: Launch

    /// Holds right away when this build is remembered as too old, and asks the feed
    /// either way. `startUpdater` must have run.
    func checkAtLaunch() {
        if Self.isHeld(minimumBuild: rememberedMinimumBuild, build: build) {
            AppDelegate.logger.info("build \(self.build ?? 0) is below the remembered minimum \(self.rememberedMinimumBuild ?? 0), holding")
            hold()
        }
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdateInformation()
    }

    /// The feed answered with an update (from a launch probe or a real check).
    func found(_ item: SUAppcastItem) {
        guard item.isCriticalUpdate else {
            forget()
            lift()
            return
        }
        required = item
        let minimum = Self.minimumBuild(in: item.propertiesDictionary, fallback: item.versionString)
        remember(minimumBuild: minimum)
        hold()
    }

    /// The feed answered that there is nothing newer, so nothing is required.
    func notFound() {
        forget()
        lift()
    }

    private func remember(minimumBuild: Int?) {
        guard let minimumBuild else { return }
        defaults.set(minimumBuild, forKey: Self.defaultsKey)
    }

    private func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: Holding

    /// Shows the window and makes the app modal to it.
    func hold() {
        guard window == nil else { return }
        isHolding = true

        let window = MandatoryUpdateWindow()
        let hosting = NSHostingController(
            rootView: MandatoryUpdateView(update: self, viewModel: controller.viewModel))
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        // The modal loop runs from the next turn: this is called from the updater's
        // delegate, which has to return for the updater to finish its check, and from
        // launch, which has to finish.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.isModal else { return }
            self.isModal = true
            NSApp.runModal(for: window)
            self.isModal = false
        }
    }

    /// Takes the window down and lets what was waiting happen.
    func lift() {
        guard let window else { return }
        if isModal { NSApp.stopModal() }
        window.close()
        self.window = nil
        isHolding = false
        required = nil
        installWhenFound = false
        let onLift = self.onLift
        self.onLift = nil
        onLift?()
    }

    // MARK: Actions

    /// Checks for the update and installs what is found.
    func updateNow() {
        installWhenFound = true
        controller.checkForUpdates()
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

/// The window Maggie is held behind. The update driver treats it as a place to show the
/// update's progress, like a terminal window, so Sparkle's own dialogs stay closed.
final class MandatoryUpdateWindow: NSWindow {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        title = Maggie.appName
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }
}

struct MandatoryUpdateView: View {
    @ObservedObject var update: MandatoryUpdate
    @ObservedObject var viewModel: UpdateViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            VStack(spacing: 6) {
                Text("\(Maggie.appName) needs an update")
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            status
                .frame(height: 36)

            HStack(spacing: 8) {
                Button("Quit") { update.quit() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                action
            }
        }
        .padding(.top, 16)
        .padding([.horizontal, .bottom], 24)
        .frame(width: 360)
    }

    private var message: String {
        if let version = update.required?.displayVersionString, !version.isEmpty {
            return "Version \(version) is required to keep going. This version can't be used until it is installed."
        }
        return "A newer version is required to keep going. This version can't be used until it is installed."
    }

    @ViewBuilder
    private var status: some View {
        switch viewModel.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(viewModel.text).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .downloading(let download):
            VStack(spacing: 4) {
                if let expected = download.expectedLength, expected > 0 {
                    ProgressView(value: Double(download.progress), total: Double(expected))
                } else {
                    ProgressView()
                }
                Text(viewModel.text).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .extracting(let extracting):
            VStack(spacing: 4) {
                ProgressView(value: extracting.progress)
                Text(viewModel.text).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .installing(let installing):
            Text(installing.appcastItem == nil ? "Installing, then restarting…" : "The update is ready. Restart to finish.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .error(let error):
            Text(error.error.localizedDescription)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .updateAvailable, .notFound, .permissionRequest:
            Color.clear
        }
    }

    @ViewBuilder
    private var action: some View {
        switch viewModel.state {
        case .error(let error):
            Button("Try Again") { error.retry() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .installing(let installing) where installing.appcastItem != nil:
            Button("Restart Now") { viewModel.state.confirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .checking, .downloading, .extracting, .installing:
            Button("Update Now") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .idle, .updateAvailable, .notFound, .permissionRequest:
            Button("Update Now") { update.updateNow() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}
