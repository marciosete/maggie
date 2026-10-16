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

Maggie serves its sessions to the Maggie Mobile app for iPhone and iPad. The Mac side
and the protocol are here; the app itself is in a separate, private repository.

- `mobile/MaggieRemote/`: the protocol package, shared by the Mac and the app. The
  Mac app compiles its sources directly (a synchronized folder in the Xcode project),
  since the release build's `xcodebuild -target` doesn't build source packages, so
  don't `import MaggieRemote` in `macos/`. Test with `swift test` in that folder.
  Keep it compatible: a newer Mac and an older app (or the reverse) must still talk,
  so add message kinds and optional fields, and advertise them in `Welcome`
  capabilities rather than changing what's there.
- `macos/Sources/Features/Remote/`: the Mac's server (Settings › Mobile). Its tests
  are `macos/Tests/Remote/`.
- A pairing link for a test client, without clicking:
  `osascript -e 'tell application id "<bundle id>" to get mobile pairing link'`.
- Voice from a device: the Mac keeps the one GPT-Live session, memory and tools
  (`macos/Sources/Features/Voice/`); the device is a handset. It sends `startVoice`,
  then streams its microphone as `voiceInput` frames on `RemoteProtocol.voiceStream`
  (16-bit mono PCM at 24 kHz, about 100 ms a frame, silence included, without stopping:
  GPT-Live's clock runs on the audio) and plays `voiceOutput` frames as they come.
  `subscribeVoice` brings `voiceState` on change and each `voiceTurn` (captions).
  `stopVoice` hands the microphone back to the Mac; with `endsVoice` it stops the voice.
  The Mac side is `RemoteVoice.swift`; the device needs an audio session that records
  and plays at once (`.playAndRecord`, voice chat mode for echo cancellation).

## Voice

`macos/Sources/Features/Voice/` is Maggie's voice: OpenAI's GPT-Live (`gpt-live-1`)
over its WebSocket, with Responses delegation to a backend model that runs Maggie
through function tools (`VoiceTools`). The key is `~/.config/ghostty/openai-api-key`
or `OPENAI_API_KEY`. Tests are `macos/Tests/Voice/`. A GPT-Live session expires two
hours after it starts (`expires_at` in `session.started`); `VoiceAgent` rolls to a new
one before that, and pauses the session after the quiet time set in Settings › Voice.
Memory and transcripts live in `~/Library/Application Support/<bundle id>/Voice/`.
Settings › Voice plays a sample of each voice (`VoicePreview`): OpenAI's speech endpoint
knows only two of GPT-Live's voices, so a sample is a brief GPT-Live session in that voice
told to say its line, ended when its audio goes quiet after speaking (the stream itself
never stops while silence goes in), and kept under `Voice/previews/`.

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
