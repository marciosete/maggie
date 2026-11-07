# Agent Development Guide

A file for [guiding coding agents](https://agents.md/) working on Maggie. Maggie is
a fork of [Ghostty](https://github.com/ghostty-org/ghostty): the terminal core,
renderer, config and shell integration are Ghostty's; the sidebar, session board,
source control, usage, voice, phone, install and update flow are Maggie's. A change
meant for Ghostty itself follows
[Ghostty's guide](https://github.com/ghostty-org/ghostty/blob/main/AGENTS.md) and
[Ghostty's AI policy](https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md),
not this file.

## Commands

- **Build:** `zig build`
  - On macOS, when you don't need the app bundle, `-Demit-macos-app=false` skips
    it and speeds compilation.
- **Test (Zig):** `zig build test`
  - Prefer `-Dtest-filter=<test name>`; the full suite is slow.
- **Test (Swift):** `macos/build.nu --action test` (runs `xcodebuild test` on the
  `Ghostty` scheme and skips `GhosttyUITests`, which need permissions a shell
  doesn't have). Everything Maggie added under `macos/Sources/Features` has tests
  in `macos/Tests`; a change in behaviour comes with a change in tests.
- **Format (Zig):** `zig fmt .`
- **Format and lint (Swift):** `swiftlint lint --strict --fix` in `macos/`
- **Format (other):** `prettier -w .`
- **Install a local build:** `fork/install.sh` (see its header). To test beside the
  official app, `APP_NAME="Maggie Dev" BUNDLE_ID=com.marciosete.maggie.dev fork/install.sh`.

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`
- Test: `zig build test-lib-vt -Dtest-filter=<filter>`
  - Prefer this when the change is in a libghostty-vt file
- All C enums in `include/ghostty/vt/` must have a `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`
  sentinel as the last entry to force int enum sizing (pre-C23 portability).

## Directory Structure

- Shared Zig core (Ghostty's): `src/`
- macOS app: `macos/`
  - Maggie's features: `macos/Sources/Features/{Session Board,Status Bar,Usage,Voice,Remote,Caffeine,Update,...}`
    and the sidebar, workspace and source control under `macos/Sources/Features/Terminal`
  - Maggie's tests: `macos/Tests`
  - The Claude Code plugin Maggie gives every session it starts: `macos/ClaudePlugin`
- Fork tooling (icon, DMG, install, signing, release helpers): `fork/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`, unchanged upstream code, not built or
  tested here.
- The Ghostty name remains in source paths, bundle resources and `~/.config/ghostty`
  on purpose; renaming them would make upstream merges harder for no benefit to users.

## Conventions

- **Commit messages are conventional commits and decide the version.**
  `feat(scope): …` is a minor release, `fix(scope): …` or `perf(scope): …` a patch,
  `!` after the type or a `BREAKING CHANGE:` footer a major. `docs`, `chore`, `ci`,
  `refactor` and `test` ship with the next release and cause none. The scope names
  what changed (`sidebar`, `board`, `workspace`, `source-control`, `usage`, `voice`,
  `remote`, `timing`, `capture`, `speaker`, `install`, `release`) and the subject is a
  sentence about what the person gets, in the voice of the ones already in the log.
  `.agents/skills/writing-commit-messages/SKILL.md` has the full guide.
- **Every push to `main` is a release.** Don't land a `feat` or `fix` you wouldn't
  ship to every Mac running Maggie within the hour.
- **Upstream is merged after each Ghostty release**, not continuously. Changes that
  touch shared files should say so, so they can be timed around a merge.
- **Nothing leaves the Mac without being listed** on
  [getmaggie.dev/privacy](https://getmaggie.dev/privacy). A new network call is a
  change to that page as well.
- Match the surrounding code: Swift in `macos/`, Zig in `src/`.

## Issues and pull requests

Don't open issues or pull requests on your own initiative; the maintainer does that.
Pull requests from contributors are by invitation after a discussion
(see [CONTRIBUTING.md](CONTRIBUTING.md)). AI assistance in contributions is welcome on
the terms in [AI_POLICY.md](AI_POLICY.md): understand every line you submit, and say
what was AI-assisted.
