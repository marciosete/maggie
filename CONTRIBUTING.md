# Contributing to Maggie

Thanks for your interest. Maggie is a small project maintained in spare time,
so a few things up front.

## Where things go

- **Terminal behaviour, rendering, config, shell integration**: that is
  Ghostty. Report it to and fix it in
  [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty), and Maggie
  gets it with the next upstream merge. If you aren't sure whether it is
  Ghostty's or Maggie's, try the official Ghostty: if it happens there too, it
  is upstream's.
- **The sidebar, workspace, source control, usage, reply timing, capture,
  speaker, caffeine, the install and update flow**: that is Maggie. Open an
  issue here.

## Issues

Issues are welcome, and the templates ask for what makes one actionable: the
Maggie, macOS, Claude Code and Codex versions, and a screenshot with session
names redacted. For anything about a session's colour or status, say what the
agent was doing at the time. Questions and ideas that aren't ready to be issues
go in [Discussions](https://github.com/marciosete/maggie/discussions).

## Pull requests

Pull requests are by invitation, after a discussion. Maggie is moving quickly
and its design lives in one head for now; a change agreed in an issue or a
discussion first lands smoothly, and one that arrives unannounced usually
can't be taken however good it is, which wastes your weekend. Open the issue,
and if the answer is "yes, please", the invitation follows. When you do send
one:

- Keep each pull request to one change. Small is good.
- Match the surrounding code: Swift in `macos/`, Zig in `src/`. Run
  `swiftlint lint --strict --fix` and `zig fmt .` before pushing.
- Everything in `macos/Sources/Features` that Maggie added has tests in
  `macos/Tests`; add to them when you change behaviour.
- Commit messages are [conventional commits](https://www.conventionalcommits.org),
  and they decide the version: `feat(scope): …` is a minor release,
  `fix(scope): …` or `perf(scope): …` a patch, and a `!` after the type or a
  `BREAKING CHANGE:` footer a major. Anything else (`docs`, `chore`, `ci`,
  `refactor`, `test`) ships with the next release but doesn't cause one. The
  scope names what changed — `sidebar`, `workspace`, `source-control`, `usage`,
  `timing`, `capture`, `speaker`, `install`, `release` — and the subject is a
  sentence about what the person gets, like the ones in the log.

## AI

Maggie is built with Claude Code, and you are welcome to use AI tools too. Two
rules: you must understand and be able to explain every line you submit, and
you must say in the pull request what was AI-assisted. See
[AI_POLICY.md](AI_POLICY.md).

## Model prices

The usage panel prices sessions from LiteLLM's rate table. A trimmed copy is
compiled into the app (`macos/Sources/Features/Usage/UsageBundledRates.swift`)
so a first launch, an offline Mac or an upstream change never leaves the panel
blank; the app downloads a fresher table when it can. Refresh the bundled copy
when prices change or a new model ships, and commit it as `feat(usage)`:

```sh
python3 fork/update-rates.py
```

## Merging from upstream

Upstream Ghostty is merged after each Ghostty release, not continuously. If
you are working on something that touches shared files, say so in the issue
so it can be timed around a merge.
