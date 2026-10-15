# macOS Ghostty Application

- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `zig build -Demit-macos-app=false` before building the macOS app to update
  the underlying Ghostty library.
- Use `macos/build.nu` to build the macOS app, do not use `zig build`
  (except to build the underlying library as mentioned above).
  - Build: `macos/build.nu [--scheme Ghostty] [--configuration Debug] [--action build]`
  - Output: `macos/build/<configuration>/Ghostty.app` (e.g. `macos/build/Debug/Ghostty.app`)
- Run unit tests directly with `macos/build.nu --action test`

## Maggie Mobile

The iPhone and iPad companion lives in `mobile/` (the plan is
`fork/plans/mobile-companion.md`, the human setup `fork/plans/mobile-companion-setup.md`):

- `mobile/MaggieRemote/`: the protocol package, shared by the Mac and the device. The
  Mac app compiles its sources directly (a synchronized folder in the Xcode project),
  since the release build's `xcodebuild -target` doesn't build source packages, so
  don't `import MaggieRemote` in `macos/`. Test with `swift test` in that folder.
- `macos/Sources/Features/Remote/`: the Mac's server (Settings › Mobile). Its tests
  are `macos/Tests/Remote/`.
- `mobile/MaggieMobile/`: the iOS app. `fork/mobile-build.sh [build | test]` builds
  libghostty-vt's xcframework and the app, and runs its tests on an iPad and an iPhone
  simulator. `fork/mobile-archive.sh` archives it for TestFlight.
- `mobile/Tools/remote-cli/`: a command-line client (`pair`, `sidebar`, `new`,
  `tail`, `send`, `close`) for checking a Mac end to end. Pair it with the link from
  `osascript -e 'tell application id "<bundle id>" to get mobile pairing link'`.
- The UI tests in `mobile/MaggieMobile/MaggieMobileUITests` drive the app against a
  running Mac when given `TEST_RUNNER_MAGGIE_PAIRING_LINK` and friends; without them
  they skip.

## AppleScript

- The AppleScript scripting definition is in `macos/Ghostty.sdef`.
- Guard AppleScript entry points and object accessors with the
  `macos-applescript` configuration (use `NSApp.isAppleScriptEnabled`
  and `NSApp.validateScript(command:)` where applicable).
- In `macos/Ghostty.sdef`, keep top-level definitions in this order:
  1. Classes
  2. Records
  3. Enums
  4. Commands
- Test AppleScript support:
  (1) Build with `macos/build.nu`
  (2) Launch and activate the app via osascript using the absolute path
      to the built app bundle:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to activate'`
  (3) Wait a few seconds for the app to fully launch and open a terminal.
  (4) Run test scripts with `osascript`, always targeting the app by
      its absolute path (not by name) to avoid calling the wrong
      application.
  (5) When done, quit via:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to quit'`
