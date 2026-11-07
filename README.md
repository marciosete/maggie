<h1>
<p align="center">
  <img src="fork/icon/Maggie.png" alt="Maggie" width="128">
  <br>Maggie
</h1>
  <p align="center">
    The Agent Development Environment for Mac. Built on Ghostty.
    <br />
    <a href="https://getmaggie.dev"><strong>getmaggie.dev</strong></a>
    ·
    <a href="https://getmaggie.dev/download">Download</a>
    <br />
    <a href="#what-it-does">What it does</a>
    ·
    <a href="#what-is-open-and-what-is-not">What is open</a>
    ·
    <a href="#install">Install</a>
    ·
    <a href="#how-it-works">How it works</a>
    ·
    <a href="#ghostty">Ghostty</a>
    ·
    <a href="#why-maggie">Why Maggie</a>
  </p>
  <p align="center">
    <a href="https://github.com/marciosete/maggie/releases/latest"><img src="https://img.shields.io/github/v/release/marciosete/maggie?display_name=tag&sort=semver&label=release" alt="Latest release"></a>
    <a href="https://github.com/marciosete/maggie/releases"><img src="https://img.shields.io/github/downloads/marciosete/maggie/total?label=downloads" alt="Downloads"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-blue" alt="MIT licence"></a>
    <a href="https://github.com/marciosete/maggie/actions/workflows/release.yml"><img src="https://github.com/marciosete/maggie/actions/workflows/release.yml/badge.svg?branch=main" alt="Tests and release on main"></a>
  </p>
</p>

<!-- Screenshots and the recording go here (launch plan, M5):
<p align="center"><img src="docs/images/sidebar.png" alt="…" width="900"></p>
<p align="center"><img src="docs/images/maggie.gif" alt="…" width="900"></p>
-->

Maggie is an ADE, an Agent Development Environment: a desktop app for running
many AI coding agents side by side, [Claude Code](https://claude.com/product/claude-code)
and [Codex](https://developers.openai.com/codex/cli), each in a session of its own,
with a sidebar and a board that show what every one of them is doing.
Run a dozen sessions across worktrees, see at a glance which ones are working,
which are waiting on you and which are done, and watch the cost and the token
rate as they go. It is a real terminal underneath, [Ghostty](https://ghostty.org):
Ghostty's renderer, Ghostty's config, Ghostty's shell integration.

Software engineering has become orchestration: several coding agents working in
parallel, each needing you at a different moment. An IDE gives you one project,
one tree, one cursor, and a terminal gives you tabs that all look alike. Neither
tells you which of your eight sessions is waiting on you, which one just
finished, or what the morning cost. Maggie is built around that job, so control
stays with you and the load on your attention does not grow with the number of
agents.

Maggie is macOS only, by design. It is an independent project and is not
affiliated with Ghostty, Anthropic or OpenAI. Your transcripts never leave the
Mac: [getmaggie.dev/privacy](https://getmaggie.dev/privacy) lists every
network call the app makes and how to turn each one off.

```sh
curl -fsSL https://getmaggie.dev/install.sh | sh
```

Maggie is free and open source, and paid for by the people who use it: if it
earns its place on your Mac, [sponsor it on GitHub](https://github.com/sponsors/marciosete)
or [buy a coffee](https://buymeacoffee.com/marciosete).

## What it does

**A new session is an agent session.** Open a tab, split or window and your
primary agent starts in it: Claude Code or Codex. **Settings…** (⌘,) says
which agents are enabled, either or both, and which is primary. In a git
repository it gets its own worktree (`claude -w`, `codex --worktree`), so what it
changes is its own, and a session opened from a worktree starts from the main
checkout, so two never share one. Settings can turn the worktrees off, and every
session then starts on the main checkout. `/exit` drops to the shell and the tab
stays. Turn it off in Settings or under **View › Start … in New Sessions**; a
shell startup file that starts an agent itself can check
`MAGGIE_CLAUDE_CODE_START`, set in these terminals (with `MAGGIE_AGENT` naming
the agent), and stand down.

**Set up for agents out of the box.** ⌘V pastes text as usual, and with only an
image on the clipboard it pastes the image into the agent: Maggie sends Claude
Code or Codex the ⌃V they read images on. ⌘-click a Markdown path in a session
and the file opens beside it, to read and edit. New terminals start in
`~/projects` when you have one, rather than your home directory;
`working-directory` in the configuration file still decides if you set it.

**Pivot between agents.** A session's menu in the sidebar hands it to the other
agent, in the same worktree: **New Session** starts it fresh, **Continue the
Conversation** writes the conversation so far out as Markdown and starts the
other agent reading it, so Codex picks up where Claude Code left off, or back
again, as often as you like. The old session stays until you close it.

**A sidebar of sessions.** Tabs are vertical, named, grouped and searchable.
Groups hold sessions, other groups and folders alike, and a folder group holds
folder groups, so the sidebar can be organised the way your work is: by client,
project and branch. Groups and folders move between windows. A session's
subagents are listed under its row while they run. A session's tab takes the
colour of what its agent is doing:

| Colour | Meaning                                                        |
| ------ | -------------------------------------------------------------- |
| blue   | working on a request                                           |
| red    | needs you: a permission, a question or a dialog                |
| yellow | finished, with edits that aren't committed yet                 |
| teal   | committed in its worktree, not yet landed on the main checkout |
| none   | finished, everything committed and landed                      |

Pick **Auto** to follow the agent, **Attention** to only light up when a
session needs you, or any fixed colour. Hover a session for its models, tokens
and cost; an extended row shows its project and what it is doing; a session
whose files can't be read says so; a speaker on the tab reads the session's last
reply aloud.

**A board.** ⌘K opens the session board: columns that sessions move through,
and work items, cards you keep by hand, that sessions are linked to. Cards take
colours and colours take labels, so a board can be read at a glance; columns
fold to a strip so the ones being worked in have the room. The board's filters
narrow the sidebar too, and each window has a board of its own.

**A status bar.** Under every window: your Claude and Codex plan limits and when
they reset, the Mac's memory, whether it is being kept awake, and the voice.

**A voice.** Turn the voice on and talk to Maggie: open a session, ask what is
waiting on you, hand a session an instruction, and she talks back. Say "hey
Maggie" to get her attention when she is muted or paused; that wake word is heard
by the Mac's own on-device recognition, nothing leaves it. While the voice is on
she announces the sessions you asked her to watch, or all of them: a permission
prompt and what it asks for, the end of a turn with the agent's last words, a
turn that died on a rate limit, a session exiting. The conversation itself runs
on OpenAI's live speech service with your own API key; hear each voice before
choosing one. The speaker on a session row reads a reply aloud with the Mac's
voices, or with ElevenLabs if you give it a key.

**A phone.** Maggie Mobile pairs an iPhone or iPad with your Mac by scanning a
QR code, on the same network or from anywhere when Tailscale runs on both, with
no Maggie server in between. It shows the sidebar and the board, streams a
session's terminal drawn by Ghostty's own engine, and takes the session actions
the sidebar takes. When a session needs you, the phone lights up: a push
notification sent from your Mac straight to Apple's push service with an APNs
key you create, held while the Mac is in use. The Mac side ships now, under
**Settings › Mobile**. **The iPhone and iPad app is coming, and it is a paid
companion app, not open source**; see [what is open and what is not](#what-is-open-and-what-is-not).

**A workspace that comes back.** Quit and reopen, and every window, tab, split
and agent session is restored where it was, resumed with `claude --resume` or
`codex resume`. New tabs open in their group's folder.

**Worktrees and source control.** A session started with `claude -w` or
`codex --worktree` runs in its own worktree. Maggie follows it: the source
control panel shows that worktree's branch, changes and commits ahead of
`main`, and an Auto tab counts what is left to commit and lands the worktree
when it is clean.

**Usage.** A panel with the cost and tokens of every Claude Code and Codex
session, by day, project and model, priced at current rates, with your Claude
and Codex plan limits alongside. The price table ships inside the app, so the
panel is never blank, and refreshes when it can. A custom range for the
accountant.

**Capture and timing.** The View menu captures a session's context, Claude Code
or Codex, as a file you can hand to anyone. A session's title bar shows how
long the reply took once the turn ends.

**Keep the Mac awake** from the sidebar, lid closed included, while the flock
works.

**The force multiplier.** Every session Maggie starts has
`/maggie:force-multiplier`, a Claude Code skill that counts the functional
lines of code that landed on the repository's default branch, in every language
it holds, per engineer-day, against a baseline of 150 lines a day, with time
and cost per milestone, and opens a dashboard. It names nobody by default; the
team is the unit. It measures volume, not value, and says so. To run it without
Maggie, copy the skill into Claude Code's personal skills folder:

```sh
mkdir -p ~/.claude/skills/force-multiplier && cd ~/.claude/skills/force-multiplier &&
for f in SKILL.md loc.sh loc-report.html; do
  curl -fsSLO "https://raw.githubusercontent.com/marciosete/maggie/main/macos/ClaudePlugin/skills/force-multiplier/$f"
done
```

Then, in any repository, ask Claude Code for the force multiplier.

Everything Ghostty does still works, and Maggie reads your existing
`~/.config/ghostty/config`.

## What is open and what is not

The Mac app, everything in this repository, is MIT licensed and stays that way.
It needs nothing paid to work fully: sessions, worktrees, the sidebar, the
board, source control, usage, the voice (with your own OpenAI key), the phone
side of pairing, and updates for as long as the project lives.

Maggie Mobile, the iPhone and iPad companion, is a paid app and is not open
source; it is how the project is funded alongside sponsorship. The protocol the
two halves speak is in this repository (`mobile/MaggieRemote`), so anyone can
see what crosses the wire and write their own client.

There is no account system, no analytics and no crash reporting in either half,
and there is no plan to add them.

## Install

Maggie installs next to the official Ghostty, under its own name and bundle
ID, with its own preferences and Dock entry. It never updates from Ghostty's
feed.

### Download

The quickest way is the one-liner, which downloads the latest signed and
notarized build and puts `Maggie.app` in `/Applications` (set `DEST` to
install elsewhere):

```sh
curl -fsSL https://getmaggie.dev/install.sh | sh
```

With Homebrew:

```sh
brew install --cask marciosete/maggie/maggie
```

Or get `Maggie.dmg` from [getmaggie.dev/download](https://getmaggie.dev/download)
or the [latest release](https://github.com/marciosete/maggie/releases/latest)
and drag Maggie to Applications. Every feature or fix pushed to `main` becomes
a release, so the latest one is always current.

Once installed, **Maggie › Check for Updates…** gets the next release from
GitHub, and Maggie can check on its own if you let it.

### From source

You need [Zig 0.17](https://ziglang.org/download/), Xcode 26 or newer and
[Claude Code](https://claude.com/product/claude-code) or
[Codex](https://developers.openai.com/codex/cli). Optionally
[SwiftLint](https://github.com/realm/SwiftLint), which the build runs if it is
installed, and Python 3 with Pillow to regenerate the icon.

```sh
git clone https://github.com/marciosete/maggie.git
cd maggie
fork/create-signing-identity.sh   # once per Mac; see below
fork/install.sh
```

`fork/install.sh` builds a release app and installs it to `/Applications/Maggie.app`.
Override `DEST` to install elsewhere (`DEST=~/Applications fork/install.sh`).

`fork/create-signing-identity.sh` creates a local certificate to sign the app
with. macOS remembers privacy answers (Photos, Documents, …) per signature, so
without it every reinstall asks again. Skip it and the app is signed ad hoc.

A Maggie installed this way updates from the releases like any other, and also
has **Maggie › Update Maggie from Source…**, which builds the checkout it was
installed from, restarts, and brings every window, tab and session back. It
runs `fork/install.sh --build-only` while you keep working, then
`--install-staged` after Maggie quits.

### Releases

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds every
push to `main` into a universal `Maggie.app`, signs and notarizes it when the
Apple secrets are set, and publishes a zip, a DMG and the Sparkle appcast as a
GitHub release. Versions are semver and the commit messages decide them, as
semantic-release does: a `feat:` is a minor release, a `fix:` or `perf:` a
patch, a breaking change a major, and a push with none of those makes no
release (see [CONTRIBUTING.md](CONTRIBUTING.md)). The release notes are the
commits, grouped. The appcast is signed with the key pairing
`fork/sparkle-public.key`; the app accepts no update that isn't.

## How it works

Maggie finds the Claude Code running in each terminal from Claude Code's own
session registry and reads the session's transcript. It starts Codex with
`--no-daemon`, so each terminal's `codex` owns its session, and with a terminal
title that names the thread, its model and its state; it finds the session from
the rollout file (`~/.codex/sessions/…`) the process keeps open and reads the
turn's state, model and edits off the end of it, and the title says when Codex
is waiting on you. A `codex` started by hand runs through Codex's shared daemon
and isn't followed. There are no hooks to install and nothing to add to either
agent's settings: the one plugin Maggie gives its Claude Code sessions carries
the force-multiplier skill and the hook that lets the voice announce events the
moment they happen.

The usage panel is computed from those transcripts and rollouts, and the plan
limits from what `claude` and `codex app-server` report.

Session state is kept in Maggie's own preferences, under its bundle ID, never
in Ghostty's.

Maggie is a terminal, not a web app wrapped around one and not a text UI inside
one, and it runs on your Mac against your files, not in a cloud sandbox. If you
want many sessions in a browser tab, or a hosted agent farm, there are tools
built for that; Maggie is for the engineer who wants the real terminal, local
worktrees, and to know at a glance who needs them.

## Ghostty

Maggie is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) by
Mitchell Hashimoto and the Ghostty contributors. It shares Ghostty's terminal
core, renderer, fonts, input handling, config and shell integration; the
sidebar, board, workspace, source control, usage, voice and phone features are
Maggie's. The GTK app for Linux is unchanged upstream code and is not built or
tested here.

Upstream changes are merged in after each Ghostty release. Ghostty's own
documentation at [ghostty.org/docs](https://ghostty.org/docs) applies to
everything Maggie inherits, and [HACKING.md](HACKING.md) to building it.

Ghostty is a trademark of its owners. Maggie uses its own name and icon, and
describes itself as built on Ghostty. See [NOTICE.md](NOTICE.md).

## Why Maggie

Australians call the Australian magpie a maggie. It sings one of the most
complex songs of any bird, remembers faces, and in spring it swoops anyone who
comes too close to the nest. A red tab in the sidebar is a maggie swooping.

## License

MIT, the same as Ghostty. Copyright © 2024 Mitchell Hashimoto, Ghostty
contributors; changes in this fork © 2026 Marcio Sete, released under the same
license. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
