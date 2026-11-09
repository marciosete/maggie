# Maggie launch plan

Written 8 November 2026. Closes every gap found in the 7 November readiness audit, in milestones with dates, owners and a "done when" for each. Uncommitted until you say go (`docs:` commits do not cause a release).

## Decisions so far (8 November)

- **GitHub Sponsors:** live. The application was started on 8 November and completed the same day; GitHub confirms the sponsor button is on the `marciosete` profile. `.github/FUNDING.yml` in this repository already names the account, so the repository's Sponsor button follows. The sponsor links in the README and site now resolve.
- **The phone:** Maggie Mobile, the iPhone and iPad app, is coming. It is a **paid companion app and not open source**. The "coming" route is taken: the pairing UI stays visible (it works today and the app is in testing) and says so in one sentence; README, site and privacy page say "coming, paid".
- **Open-core statement:** the Mac app, everything in this repository, is MIT and stays MIT, and needs nothing paid to work fully. Maggie Mobile is a paid app, not open source, and is how the project is funded alongside sponsorship. The protocol between the two halves is in this repository. No accounts, analytics or crash reporting in either half.
- **Contact email:** `marcio.sete@gmail.com` everywhere in this repository (replaces `marcio@ai-foundry.au`).
- **Force-multiplier skill:** no separate repository (see M2). The README carries a one-liner that installs it from this repository without Maggie.
- **Still open:** `free-code` (private, archived, or left); the launch date.

## Decisions, 9 November

- **LinkedIn only, for now.** The launch is the LinkedIn post with the film. Show HN, Reddit, X, the Launch FAQ and the site's FAQ section are deferred; nothing written for them is lost (the drafts are in the private repository, `marketing/launch/README.md`).
- **No release freeze.** The CI gate is the protection; `main` keeps moving.
- **No pinned discussions.** #9 Roadmap and #10 What are you running Maggie on? stay as they are.
- **The film replaces the screen recording.** A 100-second narrated film at 1.1× with captions, the app drawn in HTML and operated by a cursor; source in the private repository at `marketing/launch/film/`, review copies in `~/Downloads/maggie-launch-film/`, every check in its `VERIFY.md`.
- **The force-multiplier one-liner is tested** on a fresh account (Marcio).
- **The source control panel has no Auto tab.** The README, the site and the film said it had; the README and the site were corrected on 9 November, the film on the 8th.
- **The film is on YouTube**, public: https://youtu.be/yjvg1CKXk-Q ("Introducing Maggie — Agent Development Environment", 100 s).
- **The site's hero stays the screenshot.** The film has its own section lower down, between the feature list and the feature rows (`#film`): a still from the film with a play button, and the YouTube player in its place on the click, so nothing is requested from YouTube before then; the privacy page says so. Live 9 November.
- **No GIF** in the README, and **no link to the force-multiplier skill** from marciosete.com.
- **The baseline numbers are part of the content**: they are taken when the LinkedIn post is written.
- **Mitchell was told** by email on 9 November.
- **The launch material lives in the private repository**, under `marketing/launch/` (Marcio, 9 November): the film's source, the launch kit and the staging script. They were in the website repository, which the site serves as it is, so the kit and the staging files were readable at `getmaggie.dev/launch/…` until they were removed that day; the film had never been committed anywhere. Source only is committed (renders and the mixed audio are rebuilt by the tools), and a rebuild from the commit gave the shipped mix sample for sample.

## Where we start

Public since 22 September 2026, MIT, v0.31.0 released 27 October. Never announced. Baseline to beat, recorded 7 November:

| Measure | Value |
|---|---|
| Stars / forks / watchers | 2 / 0 / 0 |
| Issues / PRs / Discussions | 0 / 0 / 0 |
| Repo views, 14 days | 17 (6 unique) |
| Clones, 14 days | 53 (26 unique, CI included) |
| Downloads of v0.31.0 DMG | 42 |

Already done and verified: Developer ID signing, notarization with a stapled ticket (checked on the shipped DMG and app), Sparkle appcast, Homebrew cask auto-updated by the release, semver from conventional commits, privacy page, trademark notice, AI policy, contributing guide, security policy, issue templates, Discussions enabled, custom social card, topics and description.

## The date

**Decided 8 November: launch is today, 8 November 2026**, as soon as the screenshots, the recording and the launch texts are done (Marcio is doing those himself). The milestone dates below were written for a 1 December launch and now read as a checklist rather than a calendar; what has to be true before posting is the "Definition of launch-ready" at the end. One timing fact for the Show HN: 8 November is a Saturday evening and Sunday in the United States; Hacker News traffic is lowest then and competition is too. Posting it in the US Monday or Tuesday morning instead (Tuesday or Wednesday before dawn in Perth) costs a day or two and is the usual advice; the call is yours.

Earlier plan, kept for the record: Show HN on Tuesday 1 December 2026, 6–7am US Eastern (7–8pm Perth, 10–11pm Sydney); LinkedIn post on Thursday 3 December.

Why not sooner: the aggressive option was Tuesday 17 November, nine days from now, with the LinkedIn series starting on the 10th and comms sign-off still pending. The quality of the recording and the README is the launch; a week more is cheap. Why not the week after the 17th: Thursday 26 November is US Thanksgiving and that whole week is soft on Hacker News. 1 December is the first clean Tuesday.

Working rhythm assumed: evenings and weekends, as the commit history shows (70 of 176 fork commits landed between 7pm and midnight). Effort below is in evenings. Tasks marked **[A]** can be handed to a Claude Code session in this repo; **[M]** needs you (accounts, recordings, people, decisions).

## Milestones at a glance

| # | Milestone | Done by | Evenings |
|---|---|---|---|
| M0 | Decide and unblock | Mon 9 Nov | ½ |
| M1 | Trust gate: tests in CI, release waits for them | Wed 11 Nov | 1–2 |
| M2 | Force-multiplier skill installable on its own | Wed 11 Nov | 1 |
| M3 | Repository housekeeping | Sun 15 Nov | 1 |
| M4 | Product truth: README, open-core, phone, privacy, site | Fri 20 Nov | 2 |
| M5 | Assets: demo workspace, screenshots, recording | Sun 22 Nov | 2 |
| M6 | Community scaffolding | Wed 25 Nov | 1 |
| M7 | Launch content, heads-up to Ghostty, release freeze | Fri 27 Nov | 1 |
| M8 | Launch | Tue 1 – Thu 3 Dec | launch day online |
| M9 | The week after | Fri 11 Dec | ½ a day, spread |

Roughly eleven evenings over three weeks, about half of them delegable.

---

## M0 — Decide and unblock (by Mon 9 Nov)

Decisions that gate later milestones, and two applications with lead times.

- [x] **[M] GitHub Sponsors.** Applied and live on 8 November; the sponsor button is on the profile and, through `FUNDING.yml`, on this repository. The 27 November fallback is no longer needed.
- [x] **[M] The phone: "coming".** Maggie Mobile is a paid companion app, not open source, not yet released. The Mac side of pairing stays visible and says so. Revisit if TestFlight opens before launch.
- [x] **[M] Open-core statement** decided; see "Decisions so far". In the README ("What is open and what is not") and both site footers.
- [x] **[M] `free-code` deleted**, 8 November, by Marcio (the session's token lacked the `delete_repo` scope). Confirmed gone.
- [x] **[M] The channel and the date.** Decided 9 November: LinkedIn only for now; Show HN, Reddit and X deferred. The post goes in the series' slot for post 4, or earlier if Marcio moves it.

**Done when:** Sponsors application submitted; the three decisions written at the top of this file.

---

## M1 — Trust gate (by Wed 11 Nov)

The only workflow is `release.yml`, which builds, signs and publishes every `feat:`/`fix:` push to `main` without running the 65 Swift test files. Ghostty's own workflows were removed in the fork (4,638 lines of YAML deleted). Put back the one that matters.

Written 8 November, modelled on the KIT agent-harness workflows (their shape only: `contents: read`, `persist-credentials: false`, a `ci-<ref>` concurrency group with cancel-in-progress, named jobs, release depending on the gate; nothing project-specific carried over). `actionlint` passes all three files; the one note is a pre-existing shellcheck info in `release.yml`. **Verified locally on 8 November:** the exact CI invocation (unsigned Debug host, UI tests skipped) ran 765 tests, 762 passed, 0 failed, 3 skipped by the tests themselves, 52 seconds for the test phase; `zig fmt --check build.zig src` and `swiftlint lint --strict` pass; a fresh Zig cache after one build is 2.8 GB, which is why the cache limit is 6 GiB. Not verified locally: typos (no binary), the runner's cold build time, Homebrew's SwiftLint install on the macos-26 image.

- [x] **[A] `.github/workflows/test.yml`**, reusable (`workflow_call`), one job on `macos-26`, 60-minute timeout for a cold cache: `mlugg/setup-zig@v2` at **0.17.0** (what the release builds with and what `build.zig.zon` requires; the README said 0.16 and is now corrected), with the action's own cache and a 6 GiB limit; quick checks first (`zig fmt --check build.zig src`, `crate-ci/typos@v1.52.0` with `typos.toml`, SwiftLint `--strict` from Homebrew); then `zig build -Demit-macos-app=false -Dxcframework-target=native` and `xcodebuild test` on the `Ghostty` scheme, UI tests skipped, signing off, with the `.xcresult` bundle uploaded on failure.
- [x] **[A] `.github/workflows/ci.yml`**: `pull_request` and `push` to every branch but `main`, calling `test.yml`. `main` is covered by the release.
- [x] **[A] `release.yml`**: a `test` job calling `test.yml`; the release job now `needs: [test, version]`, so a red test produces no release. Nothing else changed.
- [x] **[A] README**: a badge for the release workflow on `main` (it includes the gate; `ci.yml` never runs on `main`, so its badge would mislead).
- [ ] **Prove it.** Proven on the blocking side twice on 8 November, by accident: run 1 stopped at typos (five words that were right; `typos.toml` now knows them) and run 2 stopped when the Swift test target would not compile on the runner (a chain of six `+` on `Data` inside an `#expect` in `VoiceTests.swift` that the runner's compiler could not type-check in time; it is now built in steps). Run 3 compiled and ran the suite, and three voice tests each died at exactly 60 seconds: they ask macOS for microphone permission first, and on a runner nobody answers the prompt. The gate now sets `TEST_RUNNER_MAGGIE_NO_MICROPHONE`, which xcodebuild hands to the test process, and the four tests that open the microphone are skipped there and reported as skipped; on a developer's Mac they still ask once and fail loudly if denied, as their author intended. All three times the release job was skipped, which is the gate working. **Run 4 was green** (8 November, 21:58–22:08 UTC): 9 minutes 22 seconds end to end, of which Zig setup 20 seconds from a warm cache, SwiftLint 15 seconds, the GhosttyKit build 3 minutes 5 seconds and the Swift tests 4 minutes 53 seconds; the four microphone tests reported as skipped, as designed. Well under the 15-minute target, so no warm-up run is needed. The release job followed it: **v0.31.1 published at 22:29 UTC** with the DMG, the zip and the appcast, and the Homebrew cask bumped to 0.31.1 seventeen seconds later. Every Mac running Maggie gets today's work on its next update check.

**Done when:** a red test blocks a release, the badge is green on `main`, and CI runs on pull requests.

---

## M2 — Force-multiplier skill, installable without Maggie (by Wed 11 Nov)

The 46× LinkedIn post goes out Thursday 12 November and its first comment says "run it on your own repos". The skill is built into Maggie: it lives at `macos/ClaudePlugin/skills/force-multiplier/` and every session Maggie starts has it. The gap was for the reader of that post who does not run Maggie, or a Mac: a CTO's engineer on Linux, or anyone who wants the number without installing a terminal app. The skill is three files and runs anywhere Claude Code runs.

**Decided 8 November: no separate repository, no second copy to keep in step.** The README now has a one-liner that copies the three files from this repository into Claude Code's personal skills folder (`~/.claude/skills/force-multiplier/`). One source of truth, zero maintenance.

- [x] **[A] README one-liner** under "The force multiplier", with what the skill measures and its caveats (volume not value; 150 is a convention; the team is the unit).
- [x] **[A] `loc.sh` finds `loc-report.html` beside itself** through its own `SCRIPT_DIR` (`dirname "${BASH_SOURCE[0]}"`, line 76; the page is read from `$SCRIPT_DIR/loc-report.html`, line 900), so the personal-skill install works wherever the three files sit together. The `${CLAUDE_SKILL_DIR}` in `SKILL.md` is only how Claude Code is told where to run it from.
- [x] **[M] Fresh-Mac test**: done by Marcio, 9 November.
- [ ] ~~**[A] marciosete.com**: link the skill folder from the essay where the measurement system is described (Part II, §5) and from the Research page.~~ Not needed (Marcio, 9 November).

**Done when:** a stranger with Claude Code and no Maggie installs and runs it in under ten minutes from the README alone.

---

## M3 — Repository housekeeping (by Sun 15 Nov)

- [x] **[A] Replace `AGENTS.md`.** Done 8 November: Maggie's own guide, with the build and test commands, the directory map (what is Ghostty's and what is Maggie's), the conventions from `CONTRIBUTING.md`, the every-push-is-a-release and privacy-page rules, and a pointer to Ghostty's guide for changes meant for upstream. The `CLAUDE.md` symlink stays.
- [x] **[M] Clean `origin`, branches.** Ghostty's seven branches were deleted from `origin` on 8 November (`1.1.x`, `1.2.x`, `1.3.x`, `offset-audit`, `push-tuwykoykluyz`, `setneedle-crash`, `tristan957/gtk-ng`). `origin` now has `main` only.
- [x] **[M] Clean `origin`, tags.** Done 8 November: `tip` and `v1.0.0` to `v1.3.1`, Ghostty's, deleted from `origin` by Marcio (the session's permission classifier had refused twice), and the same tags plus the local-only `v1.4.0` deleted from the clone. Every `v0.x` tag is a Maggie release and stays; the Tags page shows v0.31.1 first. Reversible: every tag still exists on the `upstream` remote.
- [x] **[M] Archive `marciosete/homebrew-tap`.** Done 8 November: its README now points at `marciosete/homebrew-maggie` with `brew untap` and the right install line, and the repository is archived (which also stops its hourly bump workflow). `homebrew-maggie` is updated by `release.yml` and is the one the README and site name.
- [x] **[A] `CODE_OF_CONDUCT.md`**, Contributor Covenant 2.1, contact `marcio.sete@gmail.com`. Ghostty has none, so this is not an inheritance.
- [x] **[A] `.github/PULL_REQUEST_TEMPLATE.md`**: what changes for the person, the commit type and scope, tests, AI-assistance statement, a three-line checklist.
- [x] **[A] Issue template `config.yml`**: contact link to the privacy page for "a network call you did not expect".
- [x] **[A] `fork/minimum-version`**: confirmed empty (comments only). No mandatory-update hold during launch week.
- [x] **Contact email** replaced in `SECURITY.md` and the new files.

**Done when:** `git ls-remote origin` lists only `main` and Maggie's tags; the four files exist; the duplicate tap is archived. All true as of 8 November.

---

## M4 — Product truth (by Fri 20 Nov)

What the README and site say must match what 0.31 does, and must say what is open and what is not.

**README (`[A]` draft, `[M]` review)**

- [x] Screenshot block at the top: an HTML comment placeholder with the two image paths M5 will fill (`docs/images/sidebar.png`, `docs/images/maggie.gif`).
- [x] "What it does" catches up with the product (8 November): **A board** (⌘K, columns, work items, colours and labels, folding columns, per window, filters narrow the sidebar), **A status bar** (plan limits, memory, keep-awake, voice), **A voice** ("hey Maggie" via on-device recognition, what it announces, OpenAI live speech with your key, the speaker with Mac voices or ElevenLabs), **A phone** (pairing by QR, same network or Tailscale, terminal drawn by Ghostty's engine, push via your APNs key held while the Mac is in use; app coming, paid), nested groups and folder groups, subagents under the row, ⌘-click Markdown, **Capture and timing**, bundled prices in Usage, **The force multiplier** with the install one-liner. Command palette, App Intents and AppleScript are Ghostty's and stay out. [M] review the voice paragraph against what the voice actually does today.
- [x] **"What is open and what is not"** section, before "Install".
- [x] **Comparables** paragraph at the end of "How it works", no names.
- [x] Sponsor ask kept; Sponsors is live as of 8 November.
- [x] Release, downloads, licence and tests-and-release badges under the title.
- [x] **The source control paragraph no longer describes an Auto tab** (there is none; found while reviewing the film, 8 November; README fixed 9 November, the site's two sentences the same day).

**The phone (`[M]`, per M0: "coming")**

- [x] `Settings › Mobile` footer says, in one sentence, that Maggie Mobile is coming and is a paid companion app and the Mac side stays free (`RemoteSettingsView.swift`; ships as `fix(remote)` or with the next `feat`). The pairing UI is not hidden: it works today and testers use it; hiding it would be a regression for them, and one honest sentence does the job.
- [x] README and site say "coming, paid"; privacy page says the Mac side ships now and the app is not yet released.

**Website (private repo `maggie-website`, cloned to `/Users/marciosete/projects/maggie-website`; `[A]` draft, `[M]` deploy with `vercel --prod`)**

- [x] Hero: the sidebar screenshot replaced the HTML mock on 8 November, in the same window frame, and the four feature panels (board, source control, usage, voice) are screenshots too; the mock's animation script is gone. ~~The recording takes the hero when it exists, with the screenshot as its poster.~~ Revised 9 November: the hero stays the screenshot, and the film has its own section lower down.
- [x] Feature parity: the site already had fifteen feature cards covering everything in the README (it was ahead of the README, not behind). The phone card now says coming and paid.
- [ ] ~~**FAQ section** with the launch FAQ from M7.~~ Deferred with the Launch FAQ (9 November).
- [x] Privacy page: destinations in the code enumerated on 8 November (getmaggie.dev appcast, the LiteLLM price file on GitHub, OpenAI live speech, ElevenLabs, Apple's push service directly), nothing new since 0.20; phone paragraph reworded (same network or Tailscale, pushes held while the Mac is in use, app not yet released); "last checked" set to 8 November 2026, Maggie 0.31.
- [x] Open-core sentence in both footers (index and privacy).
- [x] Open Graph image: `og.html` carries the sidebar screenshot beside the headline and was rendered to `assets/og.png` on 8 November.
- [x] **Deploy**: the site deploys from `main`; each push on 8 November was checked live with curl.

**Done when:** a stranger can list every feature from the README alone, knows what is free, and the site and README agree.

---

## M5 — Assets (by Sun 22 Nov)

The single largest gap: there is no screenshot or recording anywhere. **You are running this milestone in a separate stream.**

**Already in hand (found 8 November; in the private repository under `marketing/launch/staging/` since 9 November):** the website repo had `launch/staging/stage.sh`, which builds three fictional repositories (`lumen-shop`, `atlas-api`, `harbour-books`) with believable trees and histories and refuses to run inside `~/projects`, and `launch/staging/shot-list.md`, a seven-shot, 30–45 second script with the four session prompts that put the rows in four colours. Start there. Fictional repositories are safer than the personal ones suggested below, and the names match the HTML mock on the site.

- [x] ~~**[M] Demo workspace.**~~ Not needed: the film draws its workspace (the fictional repositories maggie-docs and maggie, a contributor named Alex). The staging script stays for anyone who wants a live demo.
- [x] **Screenshots** (8 November): sixteen sanitised images in `~/Downloads/maggie launch images/sanitised-for-opensource-launch`, redrawn by an image model from the real captures around a fictional contributor, Alex Morgan, and the repositories maggie, maggie-docs and maggie-tools, with the package's own review notes beside them. Six are in use: sidebar, board, source control, usage, the voice popover and a terminal. They are illustrations of the product rather than pixel-exact captures: softer glyphs, and small slips (the usage window's status bar reads `-20% 4h`; a path in the source control tree carries a stray quote). The menu bar was cropped off each. No row is red in the sidebar shot; the recording should show one.
- [x] **The film** (8 November) in place of the recording: 100 s at 1.1×, eight acts (name, the job, the colours, worktrees, the board, the voice, nothing leaves the Mac, open and close), narrated, captioned, the app drawn in HTML and operated by a cursor from the user's point of view. Source in the private repository at `marketing/launch/film/` (moved from the website repo's working copy on 9 November), review copies and one file per act in `~/Downloads/maggie-launch-film/`.
- [x] **[A] Exports from the film**, closed 9 November: the 1080p file (H.264, AAC, 100 s, 9.8 MB) uploads to LinkedIn as it is; the film is on YouTube and plays from there on the site, with a frame of it as the still (`assets/film-poster.webp`); no GIF, by decision.
- [x] **[M] The film's home** (9 November): the private repository, `marketing/launch/film/`, with the launch kit and the staging script beside it. Committed and pushed; the website repo no longer has a `launch/` folder.
- [x] **[A] Place them** (8 November): README top and beside the board, voice, source control and usage paragraphs (`docs/images/*.webp`, 23 to 149 KB each); site hero and the four feature panels (`assets/shots/*.webp`), replacing the HTML mocks; `og:image` re-rendered. The repository's social preview is the same card, uploaded through the browser on 8 November (GitHub has no API for it); the site's deploy was checked live with curl, and the hero and panels in Chrome.
- [ ] **[M] Optional, for the LinkedIn components post later**: a 2–3 minute narrated walkthrough on YouTube, which also unlocks the `/videos` page on marciosete.com.

**Done when:** README and site open on a real picture of the product. (No GIF, 9 November.)

---

## M6 — Community scaffolding (by Wed 25 Nov)

Revised 8 November after Marcio's call: **no seeded issues and no milestones.** The repository should be open to receive issues, not pre-filled with them, and the roadmap is not a list of tickets. The seven seeded issues and the two milestones were deleted the same day. What stays is structure that helps when real issues arrive, and the two discussions.

- [x] **Labels** mirroring the commit scopes: `sidebar`, `board`, `source-control`, `usage`, `voice`, `remote`, `install`, `release`, plus `upstream` and `needs-info`. Defaults kept.
- [x] **Two Discussions**: *Roadmap* (#9, Announcements) with the real roadmap, which is Maggie Mobile as a paid companion app and team and collaboration features as a paid subscription tier later, the Mac app staying MIT, and what is not planned (Linux, Windows, other agents for now); and *What are you running Maggie on?* (#10, Show and tell).
- [x] ~~**[M] Pin them.**~~ Not pinning (Marcio, 9 November).
- [ ] ~~**Third Discussion, *Launch FAQ***~~ Deferred with the Show HN content (9 November).

**Done when:** labels exist and the Issues tab is empty and open. True as of 9 November.

---

## M7 — Launch content, heads-up, freeze (by Fri 27 Nov)

**Separate piece of work, by your call.** Start from what exists: the launch kit (`marketing/launch/README.md` in the private repository since 9 November) already holds a Show HN title and first comment, X, LinkedIn and Reddit drafts, a one-line description and a checklist. It predates the 46× framing, the open-core statement and the libghostty answer, so M7 is a revision of that kit, not a blank page. The items below are what the revision has to add.

- [ ] ~~**[A] Show HN title**~~ Deferred (LinkedIn only, 9 November). Under 80 characters. The kit has `Show HN: Maggie – a Mac terminal for running many coding agents in parallel`; the alternative is `Show HN: Maggie – an agent development environment for Mac, built on Ghostty`. Pick one.
- [ ] ~~**[A] First comment**~~ Deferred with the Show HN: why you built it (46× moved the bottleneck to attention); what is Ghostty's and what is Maggie's; why a fork of the macOS app and not a libghostty embed (the sidebar, workspace, restore, splits and tabs live in the app layer, and upstream is merged after each Ghostty release); the open-core statement; the privacy page in one line; built with the agents it manages, with the force-multiplier number for this repo. Four short paragraphs, no marketing.
- [ ] ~~**[A] Launch FAQ**~~ Deferred (9 November). Eight answers, used on HN, Reddit, Discussions and the site: Why macOS only? Why a fork and not a plugin or a libghostty app? What is commercial? Does it work with Gemini CLI, opencode, aider? It reads my `~/.claude` transcripts, what leaves the Mac? Voice needs my OpenAI key, why? Linux or Windows? How does it compare with TUI session managers and cloud agent runners?
- [ ] ~~**[A] Reddit posts**~~ Deferred (9 November), for r/ClaudeAI, r/macapps, r/commandline, each in that subreddit's register, each linking the site, not the repo.
- [ ] ~~**[A] X thread**~~ Deferred (9 November).
- [ ] **[A] LinkedIn post 4** is drafted in `marciosete.com/docs/linkedin-comeback-series.md`; refresh the numbers from the M2 skill run.
- [x] **[M] Heads-up to Ghostty.** Ghostty's Discussions have no show-and-tell category and are vouch-gated, so do not post there. The note and the email are written in `docs/launch/heads-up-mitchell.md` (9 November); his site publishes `m@mitchellh.com`. **The email was sent by Marcio on 9 November.** No ask.
- [x] ~~**[M] Release freeze**~~ No freeze (Marcio, 9 November); the CI gate is the protection.
- [ ] **[M] Record the baseline** when the LinkedIn post is written; it is part of the content (9 November): stars, views, clones, downloads, site visits.

**Done when:** the LinkedIn post and the note to Mitchell exist in `docs/launch/`, and Mitchell has been told.

---

## M8 — Launch (Tue 1 Dec – Thu 3 Dec)

**Revised 9 November: LinkedIn only.** The Show HN, Reddit and X steps below are deferred and kept for the record. What remains is the LinkedIn post, on the day Marcio picks, with the film as the media and the repository and the site linked; then answering every comment, Discussion and issue within the day.

**Tuesday 1 December**

- [ ] 6–7am US Eastern: submit the Show HN with the site URL. Post the first comment at once.
- [ ] Stay online six hours. Answer every substantive comment within 20 minutes; concede what is true; never ask for votes.
- [ ] Within the hour: X thread; r/ClaudeAI. Reddit's other two the next morning, spaced.
- [ ] A `fix:` release is allowed the same day for anything that breaks first-run.
- [ ] Reply to every new Discussion and issue within the day.

**Wednesday 2 December**

- [ ] Morning check at 7am local: triage overnight issues, label, assign to milestone.
- [ ] Post the HN result in Discussions Announcements (whatever it was, honestly).

**Thursday 3 December**

- [ ] LinkedIn post 4, with the HN result in the first comment if it is good, the GIF as the media.
- [ ] Kinetic IT comms is not involved in this post; it is personal open source. Say nothing about Kinetic in it.

**Done when:** the posts are live, the first-day issues are triaged, and nothing shipped broken.

---

## M9 — The week after (to Fri 11 Dec)

- [ ] Fix the top three reported problems as `fix:` releases; thank reporters in release notes.
- [ ] Turn the best HN or Reddit questions into FAQ entries on the site.
- [ ] Thank-you Discussion with the numbers: before and after.
- [ ] marciosete.com: the field note "Why I built Maggie", with the launch numbers and what you would do differently; add Maggie to the Lab (`data/projects.ts`, status Active) if not already done in M4.
- [ ] Unfreeze: merge upstream Ghostty, resume features.
- [ ] Decide the next milestone from what people actually asked for, not the pre-launch roadmap.

---

## Effect on the LinkedIn calendar

Maggie's beat moves from 19 November to 3 December. The platform posts move up and the sequence still reads proof → discomfort → how → tool → how:

| Week | Day | Post |
|---|---|---|
| 1 | Tue 10 Nov | 1. Day 100 |
| 1 | Thu 12 Nov | 2. 46× (first comment links the standalone skill, M2) |
| 2 | Tue 17 Nov | 3. Your engineers say 3×. Your CFO sees nothing. |
| 2 | Thu 19 Nov | 5. Most enterprise agents are a chatbot with SSO |
| 3 | Tue 24 Nov | 6. The components (+ diagram) |
| 3 | Thu 26 Nov | 7. You capped Opus and called it governance |
| 4 | Tue 1 Dec | Show HN (US morning) |
| 4 | Thu 3 Dec | 4. At 46×, the bottleneck moved. Maggie. |
| 5 | Tue 8 Dec | 9. Your review queue is now the factory floor (announces the Live) |
| 5 | Thu 10 Dec | 10. Live: opening the box on 46× |

Post 8 ("Make trust less necessary") becomes an essay chapter, or a January post.

## Risks

| Risk | Mitigation |
|---|---|
| Sponsors not approved in time | M4 removes the ask; Buy Me a Coffee stays |
| TestFlight review slips | "Coming" route is ready as the default; flip when approved |
| "Why not libghostty?" dominates HN | Answer is in the first comment before anyone asks |
| A `feat:` push ships a regression on launch day | CI gate (M1) plus the freeze (M7) |
| Ghostty community feels blindsided | Direct heads-up 48 hours before (M7) |
| The profile undercuts the privacy story | `free-code` decision in M0 |
| Launch lands in a dead week | 1 December avoids Thanksgiving; no Australian holidays that week |
| Evenings run out | M3, M6 optional items and the YouTube walkthrough can slip past launch without harm |

## Definition of launch-ready

All true on Monday 30 November:

- [x] CI runs tests on PRs and `main`; release waits for green; badge is green (run 4, v0.31.1, 8 November).
- [x] README opens on a real screenshot, lists every shipped feature, states what is open and what is not. (Done 8 November. No GIF, by decision, 9 November.)
- [x] The film is on the site, below the feature list (9 November; the hero stays the screenshot, by decision); site and README agree; privacy page says "checked against 0.3x".
- [x] Sponsors live, or the ask removed.
- [x] The phone is installable or clearly "coming".
- [x] `origin` has only `main` and Maggie's tags; duplicate tap archived; `AGENTS.md` is Maggie's; code of conduct present.
- [x] Force-multiplier skill installs standalone in under ten minutes (Marcio, 9 November).
- [x] The Roadmap discussion carries the roadmap (no seeded issues, by decision). Pinning and the Launch FAQ dropped, 9 November.
- [ ] LinkedIn post 4 written, with the film. (Mitchell told, 9 November. Show HN, Reddit and X deferred; no freeze.)
- [x] `free-code` dealt with (deleted 8 November).
- [ ] Baseline numbers recorded (with the content, 9 November).

## Working agreement

One Claude Code session per milestone, in this repo, from `main`. Each task: say what will change, wait for "go", change it, confirm, tick it here. Commit types that do not release (`docs:`, `ci:`, `chore:`, `test:`) for everything in M1, M3 and M6; `feat(remote):` only for the phone setting. No push without a go. This file is the checklist; keep it current.
