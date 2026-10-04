---
name: force-multiplier
description: Measure the engineering force multiplier of this repository — functional lines of code shipped per engineer-day against a 150 LOC/day baseline, across every language it holds (product, test, pipeline, infrastructure) — with time and cost per milestone, and open the dashboard
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/loc.sh:*)
---

Strict lines-of-code accounting for the git repository Claude is working in. It
counts what landed on the default branch, in every programming language the
repository holds (detected from the files, never configured), and compares it
with 150 LOC per engineer per coding day: the **force multiplier**.

Two figures:
- **FUNCTIONAL:** every physical line.
- **NCLOC:** Sonar's rule, which drops blank and comment lines.

Views: by commit day (team, or per author), by author, by language, by workspace,
and **Time and cost** per ncloc milestone. The page shows the team only by
default; see `LOC_TEAM_ONLY`.

### Scope (the report prints the authoritative Scope block)

- **Principle:** whatever the language, the product surface is the team's
  executable code plus what lets it ship with confidence — its tests,
  pipelines and infrastructure. Build and tool configuration, test setup, data
  manifests (`.json` `.toml` `.xml`), lockfiles, prose and app content are not.
- **Product:** code in a known programming language (TypeScript/JavaScript,
  Swift, Kotlin, Zig, C/C++/Objective-C, Go, Rust, Python, Ruby, Java, C#, Dart,
  PHP, shaders, Lua, Elixir and more). A `scripts/` dir inside a package IS
  that package's code.
- **Test:** `tests/` `test/` `spec/` `__tests__/` `*Tests/` `*-tests/` `e2e/`
  `fixtures/` folders; `.test.` `.spec.`; `_test.` `_spec.`; `test_*.py`;
  `*Test.java` `*Tests.swift`; Maestro flows (YAML
  under `integration-tests/`). Tests written inline in a source file (Zig, Rust)
  count as product, because a line carries no path of its own.
- **Pipeline:** `.github/`, `.gitlab-ci.yml`, `.circleci/`, `Jenkinsfile`,
  `.buildkite/`, Azure Pipelines, `fastlane/` and the like.
- **Infrastructure:** Terraform/HCL, Dockerfiles, compose files, k8s/Helm,
  `infra/` `deploy/` `terraform/` `cdk/` `pulumi/` trees, `render.yaml`, and the
  root `scripts/` folder (release, CI and E2E tooling, shell included).
- **Not product code, wherever it sits:** build and tool configuration —
  `*.config.*` (`babel.config.js`, `jest.config.ts` …), `.*rc.js`
  (`.eslintrc.js`), `*.gradle` (Android `build.gradle`), Makefile, CMake,
  `build.zig`, `Package.swift`, Nix, Bazel, `setup.py`, `build.rs`, Gemfile,
  Podfile — and test setup: `*.setup.*` (`jest.setup.ts`), `setupTests.*`,
  `conftest.py`.
- **Not the team's code:** `vendor/` `third_party/` `node_modules/` `Pods/`
  `.yarn/`; `*.min.js` `*.pb.go` `_pb2.py` `*.g.dart` `generated/`; lockfiles;
  `docs/` `examples/` `samples/` `poc/`; AI-agent tooling (`.agents/`,
  `prompts/`); whatever `.gitattributes` marks `linguist-vendored`,
  `-generated` or `-documentation`; anything `.gitignore`d.
- **Reported, not counted:** `.css` `.scss` `.html`, and code under `assets/`
  (drawings such as SVG wrapped as TSX).
- **Comment rule (NCLOC):** `//` and `/* */` in the C family; `//` in Zig; `#`
  in Python, Ruby, YAML, shell, Dockerfiles, Make, CMake; both in Terraform,
  Nix, PHP; `--` in Lua and Haskell. Python docstrings count as code.
- **One source: what landed on the default branch.** Lines come from its
  first-parent history (`--first-parent -m`). Each entry is what one commit or
  merge changed there, dated when it landed, so a change that reached the branch
  by two routes counts once and lines a merge dropped never count. That history
  sums to today's code by construction, so the headline, the charts and the
  tables agree. A merge's lines go to whoever made the merge.
  - Every run checks this and prints `reconciled` (within 0.1%) or
    `NOT RECONCILED`. Do not quote figures from a run that is not reconciled.
- **Effort is every commit.** Engineer-days are the sum, over engineers, of each
  one's distinct commit dates, on any branch. Someone who joins on day 40 adds
  one engineer-day, not forty. A commit whose author date is before the project
  began (a wrong clock) is dated when it was committed.
- **TEAM multiplier is plain:** team lines ÷ (150 × engineer-days), the same as
  the headline. Contribution-weighting returns only with `LOC_TEAM_ONLY=0`.
- **Identities are resolved automatically.** Every git identity in history
  (email + name) is clustered into a person before anything is counted, so a
  work and a home email, a GitHub noreply address and "jrieken" next to
  "Johannes Rieken" are one engineer. Rules, strongest first (`LOC_AUTO_MERGE`):
  same email; the GitHub/GitLab noreply login; the same multi-word name written
  differently (case, accents, punctuation, word order); an email whose local
  part spells a multi-word name seen in history (`first.last`, `firstlast`,
  `flast`). A one-word name ("Tim", "unknown", "Ubuntu") never joins two
  emails. A cluster holding one bot identity (`[bot]`, dependabot, renovate,
  Copilot, github-actions, anything ending in "bot") is a bot: its lines (a
  coding agent's) stay in the team total, it is in no headcount and earns no
  engineer-day.
  A person is shown under their most-committed multi-word name. The report
  prints `N identities → P people and B bot identities; M merged`, and
  `LOC_LIST_AUTHORS=1 bash ${CLAUDE_SKILL_DIR}/loc.sh` lists every identity
  with its person, grouped by person, so a wrong merge is visible.
- **Authors: the author map** overrides the automatic merge. A tab-separated
  file mapping a git identity (author name) to a person and a role —
  `identity  person  role  evidence` — read from the first of
  `LOC_AUTHOR_FILE`, the repository's `.claude/force-multiplier/author-map.tsv`
  (committed, for the team) or `.git/loc/author-map.tsv` (this machine only).
  Keyed by name, so no email need be written down; `LOC_AUTHOR_MAP`
  (email-keyed) still works and wins. One line names, excludes or drops the
  whole cluster that identity belongs to.
  - **engineer / tester:** counted as engineers.
  - **manager / excluded:** their lines count for the team, but they are out of
    headcount, engineer-days and cost.
  - **bot:** lines for the team, no headcount, no engineer-days.
  - Roles come only from the map; the resolver never guesses one. Ask the user
    for roles; never guess one. Offer to write the map when the identity list
    shows a merge that is wrong, or a person left split.
- **Time and cost** is paid time, not commit days. Each engineer is costed for
  every weekday from first to last commit in the period (an estimate: git has
  no employment dates), at `LOC_COST_ANNUAL`, of which `LOC_WORK_DAYS` are
  worked. The table is what actually happened per ncloc milestone: the date the
  running total crossed it, how long each stretch took, who committed, the
  average team size, and the cost. Milestones not yet reached are estimated at
  the latest complete period's pace.
- **Past days are cached** in `.git/loc/` (per machine, never in the work tree).
  The cache rebuilds itself when the counting rules, the `.gitattributes`
  linguist markers or the author map change, or when a late-landing commit
  appears with an old author date.

### Settings (environment variables, all optional)

| Variable | Default | Meaning |
|---|---|---|
| `LOC_BASELINE` | `150` | LOC per engineer per coding day |
| `LOC_START_DATE` | none | `YYYY-MM-DD`. The chart starts here; earlier days are shaded as "own time" |
| `LOC_TEAM_ONLY` | `1` | The page shows the team only, with no individual names in the chart, legend, tooltips or tiles. The per-period table (By day, By month…) is always the team's. `0` restores the per-author chart, tiles and By author table |
| `LOC_COST_ANNUAL` | `150000` | All-inclusive annual cost per engineer, for "Time and cost" |
| `LOC_COST_CURRENCY` | `AUD` | Its currency |
| `LOC_WORK_DAYS` | `220` | Working days a year (260 weekdays less about 10 public holidays, 20 days' annual leave and 10 days' personal leave) |
| `LOC_DAY_TABLE_MAX` | `8` | Above this many authors the terminal day table is page-only |
| `LOC_AUTHOR_FILE` | see above | The author map |
| `LOC_AUTHOR_MAP` | none | Email-keyed merges, `email=Name;…`; `=bot` marks an account a bot |
| `LOC_AUTO_MERGE` | `1` | How identities become people: `1` every rule; `email` same email, noreply login and exact multi-word name only; `0` off (identity = author name) |
| `LOC_LIST_AUTHORS` | unset | `1` = list every identity (email, name, person, commits, first, last), grouped by person, and stop |
| `LOC_NO_OPEN` | unset | `1` = don't open the browser |

### Run

Run `bash ${CLAUDE_SKILL_DIR}/loc.sh` from the repository. It counts the default
branch (`main`, or whatever `origin/HEAD` names); from a worktree it moves to the
checkout that holds that branch. It walks history from the cache onward, prints
the terminal report, writes `.git/loc/loc-data.js`, copies the page beside it and
opens it in the default browser. Nothing it writes is in the work tree.

Do not read the figures off a truncated terminal tail. The last lines print the
page's `file://` link and the `data:` path; read that data file:
- `force`: `mult`, `nmult`, `engDaysOut`, `engDays`, `codingDays`, `how`;
- `identities`: `total`, `people`, `merged`, `bots`, `mode`;
- `tree`: `product`, `test`, `pipeline`, `infra` and their `ncloc*`
  twins, `history` against `total`, and `clean`;
- `languages`: the detected languages, largest first;
- `team.mult`; `authors`: per-author `mult`, `days`, `since`;
- `days`: find the best day here.

Do NOT paste the tables into the terminal. Reply with the conclusion first, in
plain words:

- The `file://` link on its own line, first. Say the page was opened in the browser.
- Then two or three sentences:
  - Lead with the force multiplier (raw and ncloc) and the engineer-days of output.
  - Name the main languages and the category split (product / test / pipeline /
    infra).
  - Call out the trend: the best day, and the strongest and weakest stretches.
  - Stay at team level while `teamOnly` is true: do not rank or name
    individual authors unless the user asks.
  - State the baseline: 150 LOC per engineer-day, engineer-days = sum of each
    author's distinct commit dates.
  - Flag only if:
    - the checkout has local changes (`tree.clean` is false);
    - `identities.merged` is large next to `identities.people`, or a name in
      the author table looks like a second spelling of another — say the
      resolver's rules, and that `LOC_LIST_AUTHORS=1` shows every merge;
    - the run is `NOT RECONCILED`. Say the figures cannot be quoted yet. Do
      not guess a cause.

Trust the script's numbers. Do not recount.

Caveats to repeat whenever a multiplier is quoted outside this chat:
- LOC measures volume, not value.
- 150 LOC per engineer-day is a convention for finished, reviewed human code.
- Squash-merges and merges put all of a branch's lines on the day it landed.
