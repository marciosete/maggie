---
name: force-multiplier
description: Measure the engineering force multiplier of this repository — functional lines of code shipped per engineer-day against a 150 LOC/day baseline, across every language it holds (product, test, config, pipeline, infrastructure) — and open the dashboard
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/loc.sh:*)
---

Strict lines-of-code accounting for the git repository Claude is working in. It counts the product surface in every programming language the repository holds — detected from the files, never configured — split into five categories and aggregated into a single figure:

- **product:** executable code;
- **test:** code at a test path;
- **config:** build and tool configuration written as code;
- **pipeline:** CI/CD definitions;
- **infra:** infrastructure as code.

That figure is reported two ways:
- **FUNCTIONAL:** every physical line;
- **NCLOC:** Sonar's rule, with blank and comment lines dropped.

The counted set is shown four ways:
- **By commit day:** net functional LOC from git history. There is one LOC + MULT column pair per human author, plus a TEAM pair. A `·` means that author did not commit that day. The AGGREGATE row is followed by each column's coding days.
- **By author:** a compact summary per human committer (commits, LOC, days, multiplier, first commit date), plus TEAM.
- **By language:** the current tree, per detected language.
- **By workspace:** the current tree, per package (a folder with a `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `Package.swift`, `build.zig`, Gradle/Maven file, `.csproj` or Xcode project); a file counts in its deepest package.

It then computes the overall force multiplier against a baseline of 150 LOC per engineer per coding day.

It takes no arguments: the baseline is always derived from history.

### Scope (rules the script enforces; the report prints the authoritative Scope block)

- **Principle:** whatever the language, the product surface is the team's executable code plus what lets it ship with confidence — its tests, its build configuration, its pipelines and its infrastructure. Data manifests (`.json` `.toml` `.xml`), lockfiles, prose, shell scripts and app content are not.
- **Product:** code in a known programming language (TypeScript/JavaScript, Swift, Zig, C/C++/Objective-C, Go, Rust, Python, Ruby, Java/Kotlin/Scala, C#, Dart, PHP, shaders, Lua, Elixir and more). A `scripts/` dir inside a package IS that package's code.
- **Test:** `tests/` `test/` `spec/` `__tests__/` `*Tests/` `e2e/` `fixtures/` folders; `.test.` `.spec.` `.setup.`; `_test.` `_spec.`; `test_*.py` `conftest.py`; `*Test.java` `*Tests.swift`. Tests written inline in a source file (Zig, Rust) count as product, because a line carries no path of its own.
- **Config:** Makefile, CMake, `build.zig`, `Package.swift`, `*.gradle`, `*.config.*`, `.*rc.js`, Nix, Bazel, `setup.py`, `build.rs`.
- **Pipeline:** `.github/`, `.gitlab-ci.yml`, `.circleci/`, `Jenkinsfile`, `.buildkite/`, Azure Pipelines, `fastlane/` and the like.
- **Infra:** Terraform/HCL, Dockerfiles, compose files, k8s/Helm, `infra/` `deploy/` `terraform/` `cdk/` `pulumi/` trees, `render.yaml`.
- **Not the team's code:** `vendor/` `third_party/` `node_modules/` `Pods/` `Carthage/`; `*.min.js` `*.pb.go` `_pb2.py` `*.g.dart` `generated/`; lockfiles; `docs/` `examples/` `samples/`; whatever `.gitattributes` marks `linguist-vendored`, `-generated` or `-documentation`; anything `.gitignore`d.
- **Reported but not counted:** `.css` `.scss` `.html` (the UI-assets line).
- **Comment rule (NCLOC):** `//` and `/* */` in the C family; `//` in Zig; `#` in Python, Ruby, YAML, Dockerfiles, Make, CMake; both in Terraform, Nix, PHP; `--` in Lua and Haskell. Python docstrings count as code.
- **Authors are keyed by email.** Set `LOC_AUTHOR_MAP` to merge one person's several emails, or to mark a bot:

  ```
  LOC_AUTHOR_MAP='ann@work.com=Ann Lee;ann@home.com=Ann Lee;release-bot@acme.com=bot'
  ```

  Every GitHub `[bot]` account (Dependabot and the like) is dropped automatically: bots carry no LOC, earn no engineer-days and appear in no table.
- **TEAM is contribution-weighted.** The team multiplier (per day and in aggregate) is the mean of the author multipliers, weighted by each author's share of the lines. It is never total ÷ headcount, so a part-timer cannot halve the team figure just by being present. A negative share weighs 0.
- **Merged branches are credited with what landed.** Each merge on the default branch is held to its own diff against its first parent; the branch commits it brought in share that figure by how many lines each changed. Lines a branch added and its merge then dropped (a stray snapshot, a conflict resolution) count for nobody, so history nets to the working tree.
- **Engineer-days, not engineers × days.** The baseline is the sum, over human authors, of each author's distinct commit dates. An engineer who joins on day 40 adds one engineer-day, not forty.
- **Per-day multiplier floors at 0.** A net-deletion day prints its negative net LOC (honest) but a `0.0x` multiplier, never a negative one.
- **Past days are cached** in `.git/loc/cache.tsv` (per machine, never in the work tree). Every day before today is frozen, and only history from the newest cached day onward is re-walked.
  - The cache rebuilds itself when the counting rules, the `.gitattributes` linguist markers or the author map change, or when a late-landing commit appears with an old author date.
  - The section header says `cache cold | hit | stale`.

### Settings (environment variables, all optional)

| Variable | Default | Meaning |
|---|---|---|
| `LOC_BASELINE` | `150` | LOC per engineer per coding day |
| `LOC_START_DATE` | none | `YYYY-MM-DD`. The chart starts here, and earlier commit days are shaded as "own time" (e.g. before the project officially began) |
| `LOC_AUTHOR_MAP` | none | Merges emails into one name; `=bot` drops an account |
| `LOC_NO_OPEN` | unset | `1` = don't open the browser |

### Run

Run `bash ${CLAUDE_SKILL_DIR}/loc.sh` from the repository. It always counts the default branch (`main`, or whatever `origin/HEAD` names). From a worktree, it moves to the checkout that holds that branch and counts there. Only when no checkout holds it does it count the current branch, and it prints a warning.

In order, it:

1. walks git history from the cache onward, prints the terminal report, and writes the data to `.git/loc/loc-data.js` in the repository's git directory;
2. copies the dashboard page beside the data as `.git/loc/loc-report.html` and opens it in the default browser.
   - It uses macOS `open`; `LOC_NO_OPEN=1` skips this step.
   - The page is static and reads the sibling data file: charts, per-author day table, author summary, languages, workspaces, scope.

Nothing it writes is in the work tree, so it never leaves a change behind and the repository needs no `.gitignore` entry.

The output is long, so do not read a truncated tail for the figures. The last lines print the page's `file://` link and the `data:` path. Read that data file instead:
- `force`: the headline `mult`, `engDaysOut`, `engDays`, `codingDays`, `how`;
- `tree`: `product`, `test`, `config`, `pipeline`, `infra` and their `ncloc*` twins; when `history` ≠ `total`, that's the reconciliation note;
- `languages`: the detected languages, largest first;
- `authors`: per-author `mult`, `days`, `since`;
- `team.mult`;
- `days`: find the best day here.

Do NOT paste the tables into the terminal. Reply with:

- The `file://` link on its own line, first, and say the page was opened in the browser. (The link is a fallback for a terminal where it is not clickable.)
- Then 2–3 sentences:
  - Lead with the overall force multiplier and the engineer-days-of-output figure.
  - Name the main languages found and the category split (product / test / config / pipeline / infra).
  - If there is more than one commit day, call out the trend (which day shipped most).
  - When there is more than one human author, give each leading author's multiplier and the TEAM row, and note when someone joined (the SINCE column).
  - State the baseline assumption actually used (engineer-days = the sum of each author's distinct commit dates).
  - Flag it only if:
    - an assumption looks off (e.g. coding days = 1 because every commit landed on the same date), or
    - the reconciliation "note:" line shows a large gap (history net ≠ working tree, meaning uncommitted work is in flight). A gap of a few dozen lines on a large repository is noise; say so rather than flagging it.

Trust the script's numbers. Do not recount yourself.
