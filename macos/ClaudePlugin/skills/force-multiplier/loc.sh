#!/bin/bash
#
# Strict LOC accounting + force multiplier for the git repository it is run in.
#
# Counts the product surface in whatever languages the repository holds. Every
# path goes through one classifier (AWK_RULES below) that names its language
# and comment rule and puts it in one of five categories:
#   product    executable code in a programming language
#   test       code at a test path (tests/, __tests__/, *Tests/, .test., _test., test_*.py ...)
#   config     build and tool configuration written as code (Makefile, build.zig,
#              Package.swift, *.gradle, *.config.ts, CMake, Nix, Bazel ...)
#   pipeline   CI/CD definitions (.github/, .gitlab-ci.yml, Jenkinsfile, fastlane/ ...)
#   infra      infrastructure as code (Terraform, Dockerfiles, compose, k8s/helm,
#              infra/ and deploy/ trees, render.yaml ...)
# The authoritative list is the Scope block the report prints.
# Excluded on purpose:
#   - vendored and generated code         (vendor/, third_party/, node_modules/, Pods/,
#                                          *.min.js, *.pb.go, linguist-vendored/-generated)
#   - lockfiles                           (*-lock.*, *.lock)
#   - docs/, examples/, samples/          (documentation, not the product)
#   - data and prose formats              (.json .toml .xml .md .txt, YAML outside
#                                          pipeline and infra, shell scripts)
#   - .css / .html                        (UI assets — reported separately, not counted)
#
# Functional code = product + test + config + pipeline + infra, aggregated into one count.
#
# Four views of the same counted set:
#   BY COMMIT DAY  net functional LOC (added-removed) attributed to each commit date
#   BY AUTHOR      net functional LOC attributed to each human author, plus the team
#   BY LANGUAGE    current-tree functional line counts per detected language
#   BY WORKSPACE   current-tree functional line counts per package (a folder with
#                  a package.json, go.mod, Cargo.toml, Package.swift, build.zig ...)
#
# Force multiplier: measured LOC vs a baseline of 150 LOC / engineer / coding day.
#   per day     day_LOC    / (150 x humans who committed that day)
#   per author  author_LOC / (150 x that author's distinct commit dates)
#   team        total_LOC  / (150 x engineer-days)
#   where engineer-days = the sum over human authors of their distinct commit
#   dates — an engineer who joins on day 40 adds 1 engineer-day, not 40. Bot
#   commits (semantic-release) carry no functional LOC and earn no engineer-days.
#   A multiplier is floored at 0 — a net-deletion day is not negative output.
#
# Author identity is keyed by email (one person may commit under several names).
#
# Everything the script writes (cache, data, page) goes in the repository's git
# directory, under .git/loc/, so it never shows up as a change in the work tree.
# Past days are frozen in .git/loc/cache.tsv so a run only re-walks git
# history from the newest cached day; see the cache block below for when it
# is invalidated.
#
# Usage: bash loc.sh   (from anywhere in the repository; no arguments — the baseline is always derived)
#   LOC_NO_OPEN=1          do not open the report in the browser
#   LOC_TEAM_ONLY=1        the page shows the team aggregate only, and the team multiplier
#                          is team lines / (150 x engineer-days); 0 = per author, weighted
#   LOC_DAY_TABLE_MAX=8    above this many authors the terminal day table is page-only
#   LOC_COST_ANNUAL=150000 all-inclusive annual cost per engineer, for "Time and cost"
#   LOC_COST_CURRENCY=AUD  its currency
#   LOC_WORK_DAYS=220      working days a year (260 weekdays less holidays and leave)
#   LOC_AUTHOR_FILE=path   the author map (see "authors" below)
#   LOC_LIST_AUTHORS=1     list every commit identity and stop, to build the author map
#   LOC_BASELINE=150       LOC / engineer / coding day
#   LOC_START_DATE=YYYY-MM-DD  optional: the chart starts here, and earlier days are
#                          shaded as "own time" (e.g. before the project officially began)
#   LOC_AUTHOR_MAP='a@x.com=Ann Lee;ann@home.com=Ann Lee'  merge identities by email
#
set -uo pipefail
# Every path git prints here is compared with the classifier and the disk, so
# git must print it as it is, not with its non-ASCII bytes escaped.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.quotePath GIT_CONFIG_VALUE_0=false
# The page ships beside this script; find it before leaving the caller's directory.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || { echo '  ! not inside a git repository' >&2; exit 1; }
cd "$TOPLEVEL" || exit 1

# The count is of the default branch (main, or whatever origin/HEAD names),
# never of whatever branch this checkout is on: a session worktree parked behind
# local main silently drops every commit since it forked (2026-09-24: 78 of the
# day's commits missing). So run in the checkout that has it — the shared one,
# whose working tree is the live build. Only when no checkout holds it does the
# count stay here, and it says so.
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
if [[ -z "$DEFAULT_BRANCH" ]]; then
  for b in main master trunk; do
    if git show-ref --verify --quiet "refs/heads/$b"; then DEFAULT_BRANCH=$b; break; fi
  done
fi
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
MAIN_CHECKOUT=$(git worktree list --porcelain | awk -v want="branch refs/heads/$DEFAULT_BRANCH" '
  /^worktree / { wt = substr($0, 10) }
  $0 == want { print wt; exit }')
if [[ -n "$MAIN_CHECKOUT" ]] && [[ "$MAIN_CHECKOUT" != "$PWD" ]]; then
  cd "$MAIN_CHECKOUT" || exit 1
elif [[ -z "$MAIN_CHECKOUT" ]]; then
  printf '  ! no checkout holds %s; counting %s instead\n' "$DEFAULT_BRANCH" "$(git rev-parse --abbrev-ref HEAD)" >&2
fi

# The cache, the data and the page live in the git directory, shared by every
# worktree and never part of the work tree, so no repository needs a .gitignore
# entry for them.
OUT_DIR="$(git rev-parse --path-format=absolute --git-common-dir)/loc"
mkdir -p "$OUT_DIR" || exit 1

# Local changes in the counted checkout: the headline counts them, history does
# not, so the page says so.
CLONE_DIRTY=$([[ -n "$(git status --porcelain 2>/dev/null)" ]] && echo 1 || echo 0)

# LOC_LIST_AUTHORS=1: list every commit identity (email, name, commits, first and
# last commit date) and stop. The input for the author map.
if [[ -n "${LOC_LIST_AUTHORS:-}" ]]; then
  printf 'email\tname\tcommits\tfirst\tlast\n'
  git log --format='%aE%x09%aN%x09%ad' --date=short | awk -F'\t' '
    { k=$1 "\t" $2; c[k]++; if (!(k in l) || $3>l[k]) l[k]=$3; if (!(k in f) || $3<f[k]) f[k]=$3 }
    END { for (k in c) printf "%s\t%d\t%s\t%s\n", k, c[k], f[k], l[k] }' | sort -t$'\t' -k3,3nr
  exit 0
fi

BASELINE_PER_DAY="${LOC_BASELINE:-150}"

# ---- what counts -----------------------------------------------------------
# One classifier for every path, in the working tree and in history alike, so
# the two always reconcile. classify(path) answers "category|language|comment
# style", "ui|..." for a UI asset (reported, never counted), or "" (excluded).
#
# The principles, whatever the language:
#   - Executable code in a programming language is product.
#   - Test code counts, at the paths each ecosystem keeps it: without tests the
#     product is fragile and cannot be moved at speed. Test-harness setup
#     (*.setup.*, conftest.py) is test code.
#   - Infrastructure as code, CI/CD pipelines and build configuration count for
#     the same reason: they are what lets the product ship. They count when they
#     are written as code or as a pipeline/deployment definition — never a data
#     manifest (.json .toml .xml), a lockfile or app content.
#   - Vendored, generated and documentation code is not the team's output:
#     vendor/-style folders, generated suffixes, docs/ and examples/, and
#     whatever .gitattributes marks linguist-vendored, -generated or
#     -documentation (GitHub's own markers).
#   - Shell scripts, YAML outside pipelines and infrastructure, and every
#     data or prose format are tooling, content or config data, and are excluded.
#
# Comment styles, for the ncloc rule: c (// /* */ and a " * " continuation),
# slash (// only), hash (#), hashc (# and the c forms), dash (--), semi (;),
# pct (%), ui (not counted).
AWK_RULES='
function rules() {
  lang("TypeScript", "c", "ts tsx mts cts")
  lang("JavaScript", "c", "js jsx mjs cjs")
  lang("Vue", "c", "vue"); lang("Svelte", "c", "svelte"); lang("Astro", "c", "astro")
  lang("C", "c", "c h"); lang("C++", "c", "cc cpp cxx c++ hpp hh hxx ipp inl tpp")
  lang("Objective-C", "c", "m"); lang("Objective-C++", "c", "mm")
  lang("Swift", "c", "swift"); lang("Kotlin", "c", "kt kts"); lang("Java", "c", "java")
  lang("Scala", "c", "scala sc"); lang("Groovy", "c", "groovy gradle")
  lang("Go", "c", "go"); lang("Rust", "c", "rs"); lang("C#", "c", "cs"); lang("Dart", "c", "dart")
  lang("PHP", "hashc", "php"); lang("Solidity", "c", "sol")
  lang("GLSL", "c", "glsl vert frag comp geom tesc tese"); lang("HLSL", "c", "hlsl")
  lang("Metal", "c", "metal"); lang("WGSL", "c", "wgsl")
  lang("Zig", "slash", "zig")
  lang("Terraform", "hashc", "tf tfvars"); lang("HCL", "hashc", "hcl"); lang("Bicep", "c", "bicep")
  lang("Python", "hash", "py pyi"); lang("Ruby", "hash", "rb rake gemspec"); lang("Perl", "hash", "pl pm")
  lang("R", "hash", "r R"); lang("Elixir", "hash", "ex exs"); lang("Julia", "hash", "jl")
  lang("Crystal", "hash", "cr"); lang("Nim", "hash", "nim"); lang("PowerShell", "hash", "ps1 psm1")
  lang("Nix", "hashc", "nix"); lang("CMake", "hash", "cmake"); lang("Make", "hash", "mk")
  lang("Starlark", "hash", "bzl star"); lang("YAML", "hash", "yml yaml")
  lang("Shell", "hash", "sh bash zsh")
  lang("Lua", "dash", "lua"); lang("Haskell", "dash", "hs"); lang("Elm", "dash", "elm")
  lang("Clojure", "semi", "clj cljs cljc"); lang("Emacs Lisp", "semi", "el")
  lang("Erlang", "pct", "erl hrl")
  lang("CSS", "ui", "css scss sass less"); lang("HTML", "ui", "html htm")
  named("Make", "hash", "Makefile GNUmakefile makefile")
  named("CMake", "hash", "CMakeLists.txt")
  named("Groovy", "c", "Jenkinsfile")
  named("Ruby", "hash", "Rakefile Gemfile Podfile Brewfile Fastfile Appfile Matchfile Vagrantfile Dangerfile")
  named("Just", "hash", "Justfile justfile")
  named("Starlark", "hash", "BUILD BUILD.bazel WORKSPACE WORKSPACE.bazel MODULE.bazel Tiltfile")
}
function lang(name, style, exts,   n, E, i) { n = split(exts, E, " "); for (i = 1; i <= n; i++) EXT[E[i]] = name "|" style }
function named(name, style, files,   n, F, i) { n = split(files, F, " "); for (i = 1; i <= n; i++) NAME[F[i]] = name "|" style }
BEGIN {
  rules()
  vf = ENVIRON["LOC_VENDORED"]
  if (vf != "") while ((getline vl < vf) > 0) VENDORED[vl] = 1
}
# "language|style" of a path, or "" when it is in no language this counts.
function langOf(p,   b, k) {
  b = p; sub(/^.*\//, "", b)
  if (b in NAME) return NAME[b]
  if (b ~ /(^|[.-])([Dd]ocker|[Cc]ontainer)file([.-]|$)/) return "Dockerfile|hash"
  k = match(b, /\.[^.]+$/); if (!k) return ""
  b = substr(b, k + 1)
  return (b in EXT) ? EXT[b] : ""
}
function classify(p,   L, cat) {
  if (p == "" || (p in VENDORED)) return ""
  if (p ~ /(^|\/)(node_modules|vendor|vendored|third_party|third-party|thirdparty|bower_components|jspm_packages|Pods|Carthage|docs?|documentation|examples?|samples?|\.yarn|poc|\.agents|prompts)\//) return ""
  if (p ~ /(-lock\.|\.lock$|\.min\.(js|css)$|\.pb\.(go|cc|h)$|_pb2(_grpc)?\.py$|\.g\.dart$|\.freezed\.dart$|\.generated\.[A-Za-z]+$|(^|\/)generated\/)/) return ""
  L = langOf(p); if (L == "") return ""
  if (L ~ /\|ui$/) return "ui|" L
  # code under assets/ is drawings (SVG wrapped as TSX and the like): a UI asset
  if (p ~ /(^|\/)assets?\//) return "ui|" L
  # a shell script is tooling, except in the root scripts/ that ships the product
  if (L ~ /^Shell\|/ && p !~ /^scripts\//) return ""
  # pipeline: what builds, checks and ships the product
  if (p ~ /^\.(github|gitlab|circleci|buildkite|forgejo|gitea|woodpecker|tekton|drone)\// \
      || p ~ /^(\.gitlab-ci|\.travis|\.drone|\.woodpecker|\.cirrus|appveyor|\.appveyor|azure-pipelines[^\/]*|bitbucket-pipelines|cloudbuild[^\/]*|codemagic|buildspec)\.ya?ml$/ \
      || p ~ /(^|\/)Jenkinsfile$/ || p ~ /(^|\/)fastlane\//) cat = "pipeline"
  # infrastructure: what the product runs on
  else if (p ~ /(^|\/)[^\/]*([Dd]ocker|[Cc]ontainer)file[^\/]*$/ || p ~ /\.(tf|tfvars|hcl|bicep)$/ \
      || p ~ /(^|\/)(docker-)?compose[^\/]*\.ya?ml$/ \
      || p ~ /(^|\/)(infra|infrastructure|terraform|deploy|deployments?|k8s|kubernetes|helm|kustomize|ansible|cloudformation|cdk|pulumi)\// \
      || p ~ /(^|\/)charts\/.*\.ya?ml$/ || p ~ /^(render|serverless|skaffold)\.ya?ml$/ \
      || p ~ /(^|\/)(Vagrantfile|Tiltfile)$/ || p ~ /^scripts\//) cat = "infra"
  # end-to-end flows written as YAML (Maestro) are test code
  else if (L ~ /^YAML\|/ && p ~ /(^|\/)(integration-tests|\.maestro)\//) cat = "test"
  # YAML is code only as a pipeline or a deployment; anywhere else it is content or app config
  else if (L ~ /^YAML\|/) return ""
  # test: where each ecosystem keeps it
  else if (p ~ /(^|\/)(__tests__|__mocks__|tests?|specs?|testing|testdata|fixtures|e2e|cypress|androidTest|[A-Za-z0-9_-]*Tests|[A-Za-z0-9_]+-tests?)\// \
      || p ~ /\.(test|spec|setup)\.[^\/]*$/ || p ~ /_(test|tests|spec|unittest)\.[A-Za-z0-9]+$/ \
      || p ~ /(^|\/)(test_[^\/]*|conftest)\.py$/ \
      || p ~ /(Test|Tests|Spec|Specs)\.(java|kt|kts|scala|swift|cs|php|groovy|m|mm)$/) cat = "test"
  # build and tool configuration written as code
  else if (p ~ /\.config\.[A-Za-z0-9]+$/ || p ~ /(^|\/)\.[A-Za-z0-9_-]+rc\.[cm]?[jt]s$/ \
      || p ~ /(^|\/)(Makefile|GNUmakefile|makefile|CMakeLists\.txt|Justfile|justfile|Rakefile|Gemfile|Podfile|Brewfile|Dangerfile|build\.zig|Package\.swift|setup\.py|noxfile\.py|build\.rs|BUILD|BUILD\.bazel|WORKSPACE|WORKSPACE\.bazel|MODULE\.bazel|[Gg]ulpfile\.[cm]?[jt]s|Gruntfile\.[cm]?[jt]s)$/ \
      || p ~ /\.(gradle|gradle\.kts|cmake|mk|bzl|nix|gemspec)$/) cat = "config"
  else cat = "product"
  return cat "|" L
}

# The ncloc rule. Sonar counts a physical line when it holds anything other
# than whitespace and comment. This is that rule as a pure function of ONE
# line, and it is the only classifier of lines in this script: the working
# tree and every +/- line in history go through it, so the two always
# reconcile. Being per-line it cannot see block-comment state, so it reads the
# shapes code actually uses — //, /*, */, and a " * " continuation. Prose
# inside a block comment that carries no leading star counts as code; a
# generator method (`*next()`) stays code because a star is only a comment
# when a space or slash follows. A C preprocessor line (#include) is code.
function isCode(s, style) {
  sub(/^[\t ]+/, "", s); sub(/[\t\r ]+$/, "", s)
  if (s == "") return 0
  if ((style == "hash" || style == "hashc") && s ~ /^#/) return 0
  if (style == "dash" && (s ~ /^--/ || s ~ /^\{-/ || s ~ /^-\}/)) return 0
  if (style == "semi" && s ~ /^;/) return 0
  if (style == "pct" && s ~ /^%/) return 0
  if ((style == "c" || style == "slash" || style == "hashc") && s ~ /^\/\//) return 0
  if (style == "c" || style == "hashc") {
    if (s ~ /^\/\*/ || s ~ /^\*\// || s == "*" || s ~ /^\* /) return 0
  }
  return 1
}'

# Paths .gitattributes marks linguist-vendored, -generated or -documentation,
# out of the paths on stdin; nothing when no .gitattributes mentions linguist.
LINGUIST_SIG=$(git ls-files -z -- .gitattributes '*/.gitattributes' 2>/dev/null | xargs -0 grep -h linguist 2>/dev/null | shasum | cut -c1-12)
HAS_LINGUIST=$(git ls-files -z -- .gitattributes '*/.gitattributes' 2>/dev/null | xargs -0 grep -l linguist 2>/dev/null | head -1)
linguist_excluded() {
  if [[ -z "$HAS_LINGUIST" ]]; then cat >/dev/null; return; fi
  git check-attr --stdin linguist-vendored linguist-generated linguist-documentation 2>/dev/null \
    | awk '{ if (match($0, /: linguist-(vendored|generated|documentation): (set|true)$/)) print substr($0, 1, RSTART - 1) }' | sort -u
}
export LOC_VENDORED="$OUT_DIR/vendored.txt"

# email -> display name; anything unlisted shows as its git author name.
# "bot" is the reserved name: dropped from the walk, so it is in no figure, no
# table and no engineer-day. Any GitHub App account (Dependabot and the like —
# an author name or email carrying "[bot]") folds into it without a map entry.
# Set LOC_AUTHOR_MAP to merge one person's several emails into one name, e.g.
#   LOC_AUTHOR_MAP='ann@work.com=Ann Lee;ann@home.com=Ann Lee;release-bot@acme.com=bot'
AUTHOR_MAP="${LOC_AUTHOR_MAP:-}"
# The author map: one git identity (its author NAME) per line, tab-separated:
#   identity  person  role  evidence
# role: engineer | tester (both counted as engineers) | manager or excluded (their
# lines count for the team; they are out of engineer counts, engineer-days and
# cost) | bot (dropped entirely). Keyed by name, so no email need be written down;
# LOC_AUTHOR_MAP (email-keyed) still works and wins on a clash. The first found
# of: LOC_AUTHOR_FILE, the repository's .claude/force-multiplier/author-map.tsv
# (committed, for the team), or .git/loc/author-map.tsv (this machine only).
AUTHOR_FILE="${LOC_AUTHOR_FILE:-}"
for f in "$PWD/.claude/force-multiplier/author-map.tsv" "$OUT_DIR/author-map.tsv"; do
  [[ -z "$AUTHOR_FILE" && -f "$f" ]] && AUTHOR_FILE="$f"
done
if [[ -n "$AUTHOR_FILE" && -f "$AUTHOR_FILE" ]]; then
  # manager / excluded -> the reserved name "staff" (lines for the team, no
  # headcount, engineer-days or cost); bot -> "bot"
  AUTHOR_MAP="${AUTHOR_MAP:+$AUTHOR_MAP;}$(awk -F'\t' '!/^#/ && NF>=2 && $1!="" {
    p = ($3=="manager" || $3=="excluded") ? "staff" : ($3=="bot") ? "bot" : $2
    printf "%s%s=%s", (n++ ? ";" : ""), $1, p }' "$AUTHOR_FILE")"
fi

# ---- current-tree snapshot (authoritative for "what exists now") --------
# Working-tree files: tracked + new, minus .gitignored, minus anything not on
# disk. Reflects the live state during an active build (files being moved,
# services rewritten, new work still uncommitted) — the index alone lies here.
TREE_PATHS=$(git ls-files --cached --others --exclude-standard | sort -u)
printf '%s\n' "$TREE_PATHS" | linguist_excluded > "$LOC_VENDORED"
# "path<TAB>category|language|style", one per classified file on disk
CLASSIFIED=$(printf '%s\n' "$TREE_PATHS" | awk "$AWK_RULES"'
  { c = classify($0); if (c != "") print $0 "\t" c }' \
  | while IFS= read -r line; do [[ -f "${line%%$'\t'*}" ]] && printf '%s\n' "$line"; done)

# Packages: a folder holding a package manifest (or an Xcode project), the
# repository root excepted. A file belongs to its deepest package.
WORKSPACES=$(git ls-files --cached --others --exclude-standard -- '*/package.json' '*/go.mod' '*/Cargo.toml' \
    '*/pyproject.toml' '*/setup.py' '*/Package.swift' '*/build.zig' '*/pom.xml' '*/build.gradle' '*/build.gradle.kts' \
    '*/mix.exs' '*/pubspec.yaml' '*/composer.json' '*/Gemfile' '*.csproj' '*.xcodeproj/project.pbxproj' \
  | awk '
    /(^|\/)(node_modules|vendor|vendored|third_party|third-party|thirdparty|Pods|Carthage|docs?|documentation|examples?|samples?)\// { next }
    { d = $0
      if (!sub(/\/[^\/]*$/, "", d)) next                                  # a manifest at the root
      if (d ~ /\.xcodeproj$/ && !sub(/\/[^\/]*$/, "", d)) next            # an Xcode project at the root
      print d }' | sort -u)

# Lines of every classified file: "path<TAB>raw<TAB>code", awk over the files
# themselves so each is read once; xargs may split a long list into batches.
# Paths go in as ./path so awk never reads one as a variable assignment.
PER_FILE=$(printf '%s\n' "$CLASSIFIED" | cut -f1 | grep . | sed 's|^|./|' | tr '\n' '\0' \
  | xargs -0 awk "$AWK_RULES"'
    function out() { if (f != "") printf "%s\t%d\t%d\n", substr(f, 3), raw, code }
    FNR == 1 { out(); f = FILENAME; split(langOf(f), LS, "|"); style = LS[2]; raw = 0; code = 0 }
    { raw++; if (isCode($0, style)) code++ }
    END { out() }' 2>/dev/null)

# Roll the files up into "CAT|LANG|WS<TAB>key<TAB>raw<TAB>code<TAB>files". UI
# assets have a category of their own and are in no language or package total.
TREE_SUMS=$( { printf '%s\n' "$WORKSPACES" | sed 's/^/W	/'; printf '%s\n' "$CLASSIFIED" | sed 's/^/C	/'; printf '%s\n' "$PER_FILE" | sed 's/^/L	/'; } \
  | awk -F'\t' '
    $1 == "W" { if ($2 != "") ws[$2]; next }
    $1 == "C" { split($3, P, "|"); cat[$2] = P[1]; lng[$2] = P[2]; next }
    $1 == "L" { raw[$2] = $3; code[$2] = $4; next }
    END {
      for (p in cat) {
        r = raw[p] + 0; c = code[p] + 0; k = cat[p]
        CR[k] += r; CC[k] += c; CF[k]++
        if (k == "ui") continue
        LR[lng[p]] += r; LC[lng[p]] += c; LF[lng[p]]++
        best = ""; for (w in ws) if (index(p, w "/") == 1 && length(w) > length(best)) best = w
        if (best != "") { WR[best] += r; WC[best] += c; WF[best]++ }
      }
      for (k in CR) printf "CAT\t%s\t%d\t%d\t%d\n", k, CR[k], CC[k], CF[k]
      for (k in LR) printf "LANG\t%s\t%d\t%d\t%d\n", k, LR[k], LC[k], LF[k]
      for (k in WR) printf "WS\t%s\t%d\t%d\t%d\n", k, WR[k], WC[k], WF[k]
    }')
tree_sum() {  # $1 = CAT|LANG|WS, $2 = key -> "raw<TAB>code"
  printf '%s\n' "$TREE_SUMS" | awk -F'\t' -v t="$1" -v k="$2" '$1 == t && $2 == k { r = $3; c = $4 } END { printf "%d\t%d\n", r + 0, c + 0 }'
}
IFS=$'\t' read -r PROD PROD_N <<< "$(tree_sum CAT product)"
IFS=$'\t' read -r TEST TEST_N <<< "$(tree_sum CAT test)"
IFS=$'\t' read -r CONFIG CONFIG_N <<< "$(tree_sum CAT config)"
IFS=$'\t' read -r PIPELINE PIPELINE_N <<< "$(tree_sum CAT pipeline)"
IFS=$'\t' read -r INFRA INFRA_N <<< "$(tree_sum CAT infra)"
IFS=$'\t' read -r UI _ <<< "$(tree_sum CAT ui)"
TOTAL=$((PROD + TEST + CONFIG + PIPELINE + INFRA)); TOTAL_N=$((PROD_N + TEST_N + CONFIG_N + PIPELINE_N + INFRA_N))
# "language<TAB>raw<TAB>code<TAB>files" and "package<TAB>raw<TAB>code", largest first
LANG_ROWS=$(printf '%s\n' "$TREE_SUMS" | awk -F'\t' '$1 == "LANG" { printf "%s\t%d\t%d\t%d\n", $2, $3, $4, $5 }' | sort -t$'\t' -k2,2nr)
WS_ROWS=$(printf '%s\n' "$TREE_SUMS" | awk -F'\t' '$1 == "WS" && $3 > 0 { printf "%s\t%d\t%d\n", $2, $3, $4 }' | sort -t$'\t' -k2,2nr)

# ---- historical net LOC per commit day and author -----------------------
# emits "<date>\t<author>\t<product-raw>\t<test-raw>\t<product-code>\t<test-code>\t<commits>",
# one row per (day, author), ascending by date then author. raw = every changed
# line; code = only the lines the ncloc rule counts.
#
# Past days are immutable, so their rows are cached in .git/loc/cache.tsv and
# only days from the newest cached day onward are re-walked.
# The cache is dropped whenever (a) the counting rules change — the walk below
# and the author map, which is all a cached row depends on (see CACHE_KEY) — or
# (b) the number of commits authored on/before the newest cached day differs
# from what was cached, which is what a late-landing commit with an old author
# date (rebased in after the fact) looks like.
CACHE="$OUT_DIR/cache.tsv"

# The walk diffs only files in a language the classifier knows: a pathspec and
# a forced-text attribute for each of them. The classifier decides the rest.
PATHSPECS=()
while IFS= read -r spec; do PATHSPECS+=("$spec"); done <<< "$(awk "$AWK_RULES"'
  BEGIN { for (e in EXT) print "*." e; for (n in NAME) print "*" n; print "*ockerfile*"; print "*ontainerfile*" }' | sort -u)"

# What .gitattributes excludes, among the paths history touched since $1 too.
add_linguist_history() {
  [[ -z "$HAS_LINGUIST" ]] && return
  local since="${1:-}" more
  if [[ -n "$since" ]]; then
    more=$(git log --since="$since 00:00:00" --name-only --format= --no-renames -- "${PATHSPECS[@]}" 2>/dev/null | sort -u | linguist_excluded)
  else
    more=$(git log --name-only --format= --no-renames -- "${PATHSPECS[@]}" 2>/dev/null | sort -u | linguist_excluded)
  fi
  [[ -n "$more" ]] && printf '%s\n' "$more" >> "$LOC_VENDORED"
}
TODAY=$(date +%F)

# The day the default branch began: its first commit, by committer date.
FIRST_DAY=$(git log --first-parent --max-parents=0 --format=%cd --date=short 2>/dev/null | sort | head -1)

day_rows() {  # $1 = only commits authored on/after this date ("" = whole history)
  local since="${1:-}"
  # A raw NUL byte in a source file makes git call it binary and the patch is
  # suppressed for it (2026-09-09: five files, 1,461 lines lost). Force the
  # counted languages to diff as text via a throwaway attributes file.
  local attrs; attrs=$(mktemp)
  printf '%s diff\n' "${PATHSPECS[@]}" > "$attrs"
  add_linguist_history "$since"
  # committer date >= author date, so --since on the committer clock is a safe
  # superset; the exact cut happens in awk.
  {
    # stream 1 (#K): one line per commit — the commit tally counts EVERY commit,
    # including ones that touched no counted file. Effort: engineer-days come
    # from here, every commit on every branch, dated when it was written.
    # stream 2 (#C): the lines, from what landed on the default branch: its
    # first-parent line only (--first-parent -m), so each entry is what one
    # commit or merge changed there, dated when it landed (committer date).
    # Walking every branch's commits counted a change that reached main by two
    # routes (cherry-pick, rebase + merge) twice, and lost what a merge itself
    # changed (2026-10-03: 8% high on one repository; 2026-10-04: a branch's
    # 1.4M lines of .jjconflict-* snapshots that its merge dropped). First-parent
    # history sums to the tree by construction. A merge's lines go to whoever
    # made the merge. --unified=0 emits only changed lines, no context.
    if [[ -n "$since" ]]; then
      git log --since="$since 00:00:00" --pretty=format:'#K%x09%ad%x09%aE%x09%aN%x09%cd%x09%s' --date=short
      printf '\n'
      git -c core.attributesFile="$attrs" log --first-parent -m --since="$since 00:00:00" -p --unified=0 --no-renames \
        --pretty=format:'#C%x09%cd%x09%aE%x09%aN' --date=short -- "${PATHSPECS[@]}"
    else
      git log --pretty=format:'#K%x09%ad%x09%aE%x09%aN%x09%cd%x09%s' --date=short
      printf '\n'
      git -c core.attributesFile="$attrs" log --first-parent -m -p --unified=0 --no-renames \
        --pretty=format:'#C%x09%cd%x09%aE%x09%aN' --date=short -- "${PATHSPECS[@]}"
    fi
  } 2>/dev/null | awk -F'\t' -v since="$since" -v amap="$AUTHOR_MAP" -v first="$FIRST_DAY" "$AWK_RULES"'
    # The Conventional Commits type of a subject ("fix(harness)!: ..." -> fix);
    # anything else (a merge, a free-form message) is "other".
    function ctype(subj,   t) { if (match(subj, /^[a-z]+(\([^)]*\))?!?:/)) { t=substr(subj, 1, RLENGTH); sub(/[(!:].*$/, "", t); return t } return "other" }
    # "feat:3,fix:1" -> one more of t
    function tally(list, t,   n, P, i, kv, out, hit) { n=split(list, P, ","); out=""; hit=0
      for (i=1;i<=n;i++) { if (P[i]=="") continue; split(P[i], kv, ":"); if (kv[1]==t) { kv[2]++; hit=1 }; out=out (out==""?"":",") kv[1] ":" kv[2] }
      return hit ? out : out (out==""?"":",") t ":1" }
    # by email first (LOC_AUTHOR_MAP), then by name (the author map)
    function author(email, name) { return (email in m) ? m[email] : (name in m) ? m[name] : (index(email "\t" name, "[bot]") ? "bot" : name) }
    # The path in a ---/+++ header. Git ends the header with a tab when the path
    # holds a space (2026-10-04: every Swift file under "App Intents/" was
    # dropped, 19k lines), and quotes a path holding a quote or a backslash.
    function hdrpath(s, side) {
      sub(/\t$/, "", s)
      if (substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") { s=substr(s,2,length(s)-2); gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s) }
      if (substr(s,1,2)==side) s=substr(s,3)
      return s }
    BEGIN { n=split(amap, L, ";"); for (i=1;i<=n;i++) if (L[i]!="") { k=index(L[i],"="); m[substr(L[i],1,k-1)]=substr(L[i],k+1) } }
    {
      # An author date before the project began is a wrong clock (2026-10-04: a
      # commit authored "2001-01-25", committed 2025, opened the chart in 2001):
      # such a commit is dated when it was committed.
      if ($1=="#K") { day=($2 < first) ? $5 : $2; who=author($3, $4)
                      if (since=="" || day>=since) { commits[day SUBSEP who]++; types[day SUBSEP who] = tally(types[day SUBSEP who], ctype($6)) }
                      next }
      if ($1=="#C") { cday=$2; cwho=author($3, $4)
                      cskip=(since!="" && cday<since); ckey=cday SUBSEP cwho; path=""
                      next }
      if (cskip) next
      # The file a hunk edits. A new file is "--- /dev/null", a deleted one is
      # "+++ /dev/null", so take whichever side names a real path — miss the
      # delete side and every removed line vanishes from the net.
      if (substr($0,1,4)=="--- ") { apath=hdrpath(substr($0,5), "a/"); next }
      if (substr($0,1,4)=="+++ ") {
        p=hdrpath(substr($0,5), "b/")
        if (p=="/dev/null") p=apath
        # the same classifier as the working tree; a UI asset is never counted
        cls = (p=="/dev/null") ? "" : classify(p)
        if (cls ~ /^ui\|/) cls = ""
        path = (cls == "") ? "" : p
        split(cls, CL, "|"); style = CL[3]
        isT = (CL[1] == "test")
        next }
      if (substr($0,1,11)=="diff --git ") { path=""; apath=""; next }
      if (substr($0,1,2)=="@@") next
      if (substr($0,1,1)=="\\") next                    # "\ No newline at end of file"
      if (path=="") next
      c=substr($0,1,1); if (c!="+" && c!="-") next
      d=(c=="+") ? 1 : -1; body=substr($0,2)
      if (isT) { traw[ckey]+=d; if (isCode(body, style)) tcode[ckey]+=d }
      else     { praw[ckey]+=d; if (isCode(body, style)) pcode[ckey]+=d }
    }
    # Iterate commits AND patch keys: a change dated by when it landed can sit
    # on a (day, author) that authored no commit that day; its lines still count.
    END { for (k in commits) all[k]; for (k in praw) all[k]; for (k in traw) all[k]
          for (k in all) { split(k, parts, SUBSEP)
            if (parts[2] == "bot") continue          # release bot, [bot] accounts: never counted, never shown
            printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n", parts[1], parts[2],
              (praw[k]+0), (traw[k]+0), (pcode[k]+0), (tcode[k]+0), (commits[k]+0), types[k] } }
  ' | sort
  rm -f "$attrs"
}
commits_through() { git log --pretty=%ad --date=short 2>/dev/null | awk -v d="$1" '$1<=d' | wc -l | tr -d ' '; }

# Keyed on what a cached row depends on — the walk itself, the classifier and
# per-line rule, the .gitattributes linguist markers and the author map — never
# on the whole script, so an edit to the report or the publish step keeps the
# cache warm.
CACHE_KEY=$( { declare -f day_rows add_linguist_history; printf '%s\n' "$AWK_RULES" "$LINGUIST_SIG" "$AUTHOR_MAP" "$FIRST_DAY"; } | shasum | cut -c1-12)

CACHED_ROWS=""; CACHE_LAST=""; CACHE_STATE="cold"
if [[ -f "$CACHE" ]]; then
  IFS=$'\t' read -r _ ckey clast ccount < "$CACHE"
  if [[ "${ckey:-}" = "$CACHE_KEY" ]] && [[ -n "${clast:-}" ]] && [[ "$(commits_through "$clast")" = "${ccount:-}" ]]; then
    CACHED_ROWS=$(tail -n +2 "$CACHE"); CACHE_LAST="$clast"; CACHE_STATE="hit"
  else
    CACHE_STATE="stale"
  fi
fi

if [[ -n "$CACHE_LAST" ]]; then
  # re-walk from the day AFTER the newest cached day; cached days are frozen
  NEXT=$(date -j -f %F -v+1d "$CACHE_LAST" +%F 2>/dev/null || date -d "$CACHE_LAST + 1 day" +%F)
  FRESH_ROWS=$(day_rows "$NEXT")
  ROWS=$(printf '%s\n%s\n' "$CACHED_ROWS" "$FRESH_ROWS" | grep . | sort)
else
  ROWS=$(day_rows "")
fi

# freeze every day before today (today may still receive commits)
FROZEN=$(echo "$ROWS" | awk -F'\t' -v t="$TODAY" '$1<t')
if [[ -n "$FROZEN" ]]; then
  FLAST=$(echo "$FROZEN" | tail -1 | cut -f1)
  { printf '#loc-cache\t%s\t%s\t%s\n' "$CACHE_KEY" "$FLAST" "$(commits_through "$FLAST")"; echo "$FROZEN"; } > "$CACHE"
fi

# ---- roll-ups -------------------------------------------------------------
# per day:    "<date>\t<raw>\t<ncloc>\t<commits>\t<humans>"
DAY_ROWS=$(echo "$ROWS" | awk -F'\t' '
  { d=$1; f[d]+=$3+$4; nf[d]+=$5+$6; c[d]+=$7; if ($2!="bot" && $2!="staff" && $7>0) h[d]++; days[d] }
  END { for (d in days) printf "%s\t%d\t%d\t%d\t%d\n", d, f[d], nf[d], c[d], (h[d]+0) }' | sort)
# per author: "<author>\t<raw>\t<ncloc>\t<commits>\t<days>\t<since>"   (bots excluded)
AUTHOR_ROWS=$(echo "$ROWS" | awk -F'\t' '
  $2!="bot" && $2!="staff" { a=$2; f[a]+=$3+$4; nf[a]+=$5+$6; c[a]+=$7; if ($7>0 && !((a SUBSEP $1) in seen)) { seen[a SUBSEP $1]; dd[a]++ }; first[a]=(first[a]==""||$1<first[a])?$1:first[a] }
  END { for (a in f) printf "%s\t%d\t%d\t%d\t%d\t%s\n", a, f[a], nf[a], c[a], dd[a], first[a] }' | sort -t$'\t' -k2,2nr)

DAYS_ACTUAL=$(echo "$DAY_ROWS" | grep -c . || echo 1)
[[ "${DAYS_ACTUAL:-0}" -lt 1 ]] && DAYS_ACTUAL=1
ENG_DAYS_ACTUAL=$(echo "$AUTHOR_ROWS" | awk -F'\t' '{ s+=$5 } END { print s+0 }')
[[ "${ENG_DAYS_ACTUAL:-0}" -lt 1 ]] && ENG_DAYS_ACTUAL=1
HUMANS=$(echo "$AUTHOR_ROWS" | grep -c . || echo 1)

BASELINE_ENG_DAYS=$ENG_DAYS_ACTUAL; BASELINE_HOW="sum of each author's distinct commit dates"
BASELINE=$((BASELINE_PER_DAY * BASELINE_ENG_DAYS))
MULT=$(awk -v a="$TOTAL" -v b="$BASELINE" 'BEGIN{ printf (b>0 ? "%.1f" : "0.0"), (b>0 ? a/b : 0) }')
ENG_DAYS_OUT=$(awk -v a="$TOTAL" -v d="$BASELINE_PER_DAY" 'BEGIN{ printf "%.1f", a/d }')
MULT_N=$(awk -v a="$TOTAL_N" -v b="$BASELINE" 'BEGIN{ printf (b>0 ? "%.1f" : "0.0"), (b>0 ? a/b : 0) }')
ENG_DAYS_OUT_N=$(awk -v a="$TOTAL_N" -v d="$BASELINE_PER_DAY" 'BEGIN{ printf "%.1f", a/d }')

# ---- report -------------------------------------------------------------
printf '  ═══════════════════════════════════════════════════════════\n'
printf '        🔧  AGENTIC ENGINEERING DASHBOARD  🏆\n'
printf '  ═══════════════════════════════════════════════════════════\n\n'

# author order for the day table: by first commit date; header uses the first name
AUTHORS=$(echo "$AUTHOR_ROWS" | sort -t$'\t' -k6,6 | cut -f1 | paste -sd ';' -)
printf '  BY COMMIT DAY (net functional LOC per author, from git history; cache %s%s)\n' "$CACHE_STATE" "$([[ -n "$CACHE_LAST" ]] && echo ", frozen through $CACHE_LAST")"
# One column group per author: fine for a small team, but 38 authors over 450+
# days is a table of hundreds of KB. Past LOC_DAY_TABLE_MAX authors it lives on
# the page only.
if [[ "$HUMANS" -gt "${LOC_DAY_TABLE_MAX:-8}" ]]; then
  printf '  %s authors over %s days — the per-author day table is on the HTML page only\n' "$HUMANS" "$DAYS_ACTUAL"
  printf '  (set LOC_DAY_TABLE_MAX=%s to print it here).\n\n' "$HUMANS"
else
echo "$ROWS" | awk -F'\t' -v authors="$AUTHORS" -v base="$BASELINE_PER_DAY" '
  function mraw(loc, engdays,   m) { m = (engdays>0 ? loc/(base*engdays) : 0); if (m<0) m=0; return m }
  function mult(loc, engdays) { return sprintf("%.1fx", mraw(loc, engdays)) }
  function cell(cm, loc, present, engdays) { return present ? sprintf("%4d %8d %7s", cm, loc, mult(loc, engdays)) : sprintf("%4s %8s %7s", "·", "·", "·") }
  # team multiplier = contribution-weighted mean of the author multipliers: each
  # multiplier weighted by that author share of the lines (a negative share
  # weighs 0), so a large contributor pulls the team figure toward their own rate
  # and a part-timer cannot halve it just by being present.
  function tcell(d, cm, total, present,   i, w, num, den, a) {
    if (!present) return sprintf("%4s %8s %7s", "·", "·", "·");
    for (i=1;i<=n;i++) { a=A[i]; if (d=="" ? !(a in tot) : !((d,a) in has)) continue;
      w = (d=="" ? tot[a] : loc[d,a]); if (w<0) w=0;
      num += mraw(w, (d=="" ? ad[a] : 1)) * w; den += w }
    return sprintf("%4d %8d %7s", cm, total, sprintf("%.1fx", den>0 ? num/den : 0)) }
  BEGIN {
    n=split(authors, A, ";");
    hdr=sprintf("  %-12s %7s", "DATE", "COMMITS"); sep=sprintf("  %-12s %7s", "------------", "-------");
    for (i=1;i<=n;i++) { split(A[i], nm, " "); hdr=hdr sprintf("  %4s %8s %7s", "CMT", toupper(nm[1]), "MULT"); sep=sep sprintf("  %4s %8s %7s", "----", "--------", "----") }
    hdr=hdr sprintf("  %4s %8s %7s", "CMT", "TEAM", "MULT"); sep=sep sprintf("  %4s %8s %7s", "----", "--------", "----");
    print hdr; print sep
  }
  { d=$1; a=$2; if (!(d in days)) { days[d]; D[++m]=d }   # input is date-sorted
    c[d]+=$7; if (a=="bot") next;
    if (a=="staff") { hc[d]+=$7; dtot[d]+=$3+$4; next }   # managers: lines for the team, no headcount
    cm[d,a]+=$7; acm[a]+=$7; hc[d]+=$7;
    loc[d,a]+=$3+$4; has[d,a]=1; tot[a]+=$3+$4; dtot[d]+=$3+$4;
    if ($7>0 && !((d,a) in seen)) { seen[d,a]; ad[a]++; h[d]++ } }
  END {
    for (k=1;k<=m;k++) { d=D[k]; line=sprintf("  %-12s %7d", d, c[d]);
      for (i=1;i<=n;i++) line=line "  " cell(cm[d,A[i]], loc[d,A[i]], has[d,A[i]], 1);
      line=line "  " tcell(d, hc[d], dtot[d], h[d]>0); print line; T+=dtot[d]; C+=c[d]; HC+=hc[d]; E+=h[d] }
    print sep; line=sprintf("  %-12s %7d", "AGGREGATE", C);
    for (i=1;i<=n;i++) line=line "  " cell(acm[A[i]], tot[A[i]], 1, ad[A[i]]);
    line=line "  " tcell("", HC, T, 1); print line;
    note=sprintf("  %-12s %7s", "(days)", "");
    for (i=1;i<=n;i++) note=note sprintf("  %4s %8d %7s", "", ad[A[i]], "");
    note=note sprintf("  %4s %8d %7s", "", E, ""); print note;
    print "  COMMITS = the day total; CMT = that author. Bots (release, [bot] accounts) are not counted anywhere."; print ""
  }'
fi
HIST_TOTAL=$(echo "$DAY_ROWS" | awk -F'\t' '{s+=$2} END{print s+0}')
HIST_TOTAL_N=$(echo "$DAY_ROWS" | awk -F'\t' '{s+=$3} END{print s+0}')
HIST_COMMITS=$(echo "$DAY_ROWS" | awk -F'\t' '{s+=$4} END{print s+0}')
# team multiplier on history = contribution-weighted mean of the author multipliers.
# Vault default (LOC_TEAM_ONLY=1) is the plain ratio instead, team lines over
# 150 x engineer-days, so the terminal, the page and the headline agree.
if [[ "${LOC_TEAM_ONLY:-1}" = 1 ]]; then
HIST_MULT=$(awk -v a="$HIST_TOTAL" -v b="$((BASELINE_PER_DAY * ENG_DAYS_ACTUAL))" 'BEGIN{ m=(b>0?a/b:0); if (m<0) m=0; printf "%.1f", m }')
HIST_MULT_N=$(awk -v a="$HIST_TOTAL_N" -v b="$((BASELINE_PER_DAY * ENG_DAYS_ACTUAL))" 'BEGIN{ m=(b>0?a/b:0); if (m<0) m=0; printf "%.1f", m }')
else
HIST_MULT=$(echo "$AUTHOR_ROWS" | awk -F'\t' -v base="$BASELINE_PER_DAY" '
  { w=$2; if (w<0) w=0; m=($5>0 ? $2/(base*$5) : 0); if (m<0) m=0; num+=m*w; den+=w }
  END { printf "%.1f", (den>0 ? num/den : 0) }')
HIST_MULT_N=$(echo "$AUTHOR_ROWS" | awk -F'\t' -v base="$BASELINE_PER_DAY" '
  { w=$3; if (w<0) w=0; m=($5>0 ? $3/(base*$5) : 0); if (m<0) m=0; num+=m*w; den+=w }
  END { printf "%.1f", (den>0 ? num/den : 0) }')
fi

# History (the default branch, first-parent) must sum to the tree. Within 0.1%
# is scope edge cases (a file with no final newline, odd template filenames) and
# is reported as reconciled; beyond that it is a real discrepancy, stated
# without guessing.
GAP=$((TOTAL - HIST_TOTAL))
RECONCILED=$(awk -v g="$GAP" -v t="$TOTAL" 'BEGIN{ print ((g<0?-g:g) <= 0.001*t) ? 1 : 0 }')
if [[ "$CLONE_DIRTY" = 1 ]]; then
  printf '  WARNING: the checkout has local changes. The headline counts them; history\n'
  printf '           on %s does not. Commit or set them aside for a clean figure.\n\n' "$DEFAULT_BRANCH"
fi
if [[ "$RECONCILED" = 1 ]]; then
  printf '  reconciled: history on %s sums to %s, the tree holds %s (Δ %+d, within 0.1%%).\n\n' "$DEFAULT_BRANCH" "$HIST_TOTAL" "$TOTAL" "$GAP"
else
  printf '  NOT RECONCILED: history on %s sums to %s but the tree holds %s (Δ %+d).\n' "$DEFAULT_BRANCH" "$HIST_TOTAL" "$TOTAL" "$GAP"
  printf '        Charts and headline disagree by that much. Cause not traced; investigate\n'
  printf '        before quoting figures.\n\n'
fi

printf '  BY AUTHOR (net functional LOC, from git history; bots excluded; identity keyed by email)\n'
printf '  %-14s %8s %11s %8s %6s %8s %8s  %s\n' 'AUTHOR' 'COMMITS' 'FUNCTIONAL' 'NCLOC' 'DAYS' 'MULT' 'NMULT' 'SINCE'
printf '  %-14s %8s %11s %8s %6s %8s %8s  %s\n' '--------------' '-------' '----------' '--------' '----' '----' '-----' '----------'
while IFS=$'\t' read -r a af an ac ad afirst; do
  [[ -z "${a:-}" ]] && continue
  amult=$(awk -v a="$af" -v b="$((BASELINE_PER_DAY * ad))" 'BEGIN{ m=(b>0 ? a/b : 0); if (m<0) m=0; printf "%.1f", m }')
  anmult=$(awk -v a="$an" -v b="$((BASELINE_PER_DAY * ad))" 'BEGIN{ m=(b>0 ? a/b : 0); if (m<0) m=0; printf "%.1f", m }')
  printf '  %-14s %8s %11s %8s %6s %7sx %7sx  %s\n' "$a" "$ac" "$af" "$an" "$ad" "$amult" "$anmult" "$afirst"
done <<< "$AUTHOR_ROWS"
printf '  %-14s %8s %11s %8s %6s %8s %8s  %s\n' '--------------' '-------' '----------' '--------' '----' '----' '-----' '----------'
printf '  %-14s %8s %11s %8s %6s %7sx %7sx  %s\n\n' "TEAM" "$(echo "$AUTHOR_ROWS" | awk -F'\t' '{s+=$4} END{print s+0}')" "$HIST_TOTAL" "$HIST_TOTAL_N" "$ENG_DAYS_ACTUAL" "$HIST_MULT" "$HIST_MULT_N" "$HUMANS engineer(s); DAYS = engineer-days; MULT = $([[ "${LOC_TEAM_ONLY:-1}" = 1 ]] && echo 'team lines ÷ (baseline × engineer-days)' || echo contribution-weighted)"

printf '  BY LANGUAGE (current tree; detected, not configured)\n'
printf '  %-22s %7s %11s %10s %7s\n' 'LANGUAGE' 'FILES' 'FUNCTIONAL' 'NCLOC' 'SHARE'
printf '  %-22s %7s %11s %10s %7s\n' '----------------------' '-----' '----------' '--------' '-----'
LANG_JSON=""
while IFS=$'\t' read -r lname lraw lcode lfiles; do
  [[ -z "${lname:-}" ]] && continue
  printf '  %-22s %7s %11s %10s %6s%%\n' "$lname" "$lfiles" "$lraw" "$lcode" "$(awk -v a="$lraw" -v b="$TOTAL" 'BEGIN{printf "%.1f", (b>0?100*a/b:0)}')"
  LANG_JSON="${LANG_JSON:+$LANG_JSON,}{\"name\":\"$lname\",\"files\":$lfiles,\"loc\":$lraw,\"ncloc\":$lcode}"
done <<< "$LANG_ROWS"
printf '  %-22s %7s %11s %10s %7s\n\n' '----------------------' '-----' '----------' '--------' '-----'

WS_JSON=""
printf '  BY WORKSPACE (current tree; a file belongs to its deepest package)\n'
printf '  %-28s %11s %10s\n' 'WORKSPACE' 'FUNCTIONAL' 'NCLOC'
printf '  %-28s %11s %10s\n' '----------------------------' '----------' '--------'
while IFS=$'\t' read -r pkg wtotal wntotal; do
  [[ -z "${pkg:-}" ]] && continue
  printf '  %-28s %11s %10s\n' "$pkg" "$wtotal" "$wntotal"
  WS_JSON="${WS_JSON:+$WS_JSON,}{\"name\":\"$pkg\",\"loc\":$wtotal,\"ncloc\":$wntotal}"
done <<< "$WS_ROWS"
printf '  %-28s %11s %10s\n' '----------------------------' '----------' '--------'
printf '  %-28s %11s %10s\n\n' 'TOTAL' "$TOTAL" "$TOTAL_N"

printf '  Functional LOC            %8s   (product + test + config + pipeline + infrastructure)\n' "$TOTAL"
printf '    product                 %8s   (executable code)\n' "$PROD"
printf '    test                    %8s   (code at a test path)\n' "$TEST"
printf '    config                  %8s   (build and tool configuration written as code)\n' "$CONFIG"
printf '    pipeline                %8s   (CI/CD definitions)\n' "$PIPELINE"
printf '    infrastructure          %8s   (terraform, Dockerfiles, compose, k8s/helm, infra/ and deploy/)\n' "$INFRA"
printf '  ncloc (code only)         %8s   (%s%% of raw — blank + comment lines dropped)\n' "$TOTAL_N" "$(awk -v a="$TOTAL_N" -v b="$TOTAL" 'BEGIN{printf "%.0f", (b>0?100*a/b:0)}')"
printf '  UI assets (css/html)      %8s   (excluded from multiplier)\n\n' "$UI"

printf '  ── Force multiplier ───────────────────────────────────────\n'
printf '  Baseline                  %8s   LOC / engineer / coding day\n' "$BASELINE_PER_DAY"
printf '  Engineers                 %8s   (human authors in history)\n' "$HUMANS"
printf '  Coding days               %8s   (distinct dates someone committed)\n' "$DAYS_ACTUAL"
printf '  Engineer-days             %8s   (%s)\n' "$BASELINE_ENG_DAYS" "$BASELINE_HOW"
printf '  Expected @ baseline       %8s   LOC (%s × %s engineer-days)\n' "$BASELINE" "$BASELINE_PER_DAY" "$BASELINE_ENG_DAYS"
printf '  Output in engineer-days   %8s   (%s LOC ÷ %s)\n' "$ENG_DAYS_OUT" "$TOTAL" "$BASELINE_PER_DAY"
printf '  ▶  FORCE MULTIPLIER       %7sx   (raw lines)\n' "$MULT"
printf '  ▶  ON NCLOC               %7sx   (%s code lines ÷ %s, = %s engineer-days)\n\n' "$MULT_N" "$TOTAL_N" "$BASELINE" "$ENG_DAYS_OUT_N"

printf '  ── Scope (what these numbers count) ───────────────────────\n'
printf '  Two metrics            FUNCTIONAL = every physical line; NCLOC = only\n'
printf '                         lines holding a non-whitespace, non-comment\n'
printf '                         character (Sonar\x27s rule; a trailing comment or\n'
printf '                         a lone } still counts). One per-line classifier\n'
printf '                         serves the tree and the history, so both reconcile.\n'
printf '  Languages              detected from the files, not configured: every\n'
printf '                         programming language the classifier knows (the\n'
printf '                         BY LANGUAGE table lists the ones found here).\n'
printf '  Counted (multiplier)   what landed on the default branch (its first-parent\n'
printf '                         history, so a change merged by two routes counts once),\n'
printf '                         aggregated: product + test + config + pipeline +\n'
printf '                         infrastructure.\n'
printf '  Product                executable code. A scripts/ dir inside a package\n'
printf '                         IS that package.\n'
printf '  Test                   code at a test path: tests/ test/ spec/ __tests__/\n'
printf '                         *Tests/ *-tests/ e2e/ fixtures/; .test. .spec. .setup.;\n'
printf '                         _test. _spec.; test_*.py conftest.py; *Test.java\n'
printf '                         *Tests.swift; Maestro flows (integration-tests/ YAML).\n'
printf '                         Tests inline in a source file (Zig, Rust) count as\n'
printf '                         product: a line has no path of its own.\n'
printf '  Config                 build and tool configuration written as code:\n'
printf '                         Makefile, CMake, build.zig, Package.swift, *.gradle,\n'
printf '                         *.config.*, .*rc.js, Nix, Bazel, setup.py, build.rs.\n'
printf '  Pipeline               CI/CD: .github/ .gitlab-ci.yml .circleci/ Jenkinsfile\n'
printf '                         .buildkite/ azure-pipelines fastlane/ and the like.\n'
printf '  Infrastructure         Terraform/HCL, Dockerfiles, compose, k8s/helm,\n'
printf '                         infra/ deploy/ terraform/ cdk/ pulumi/ trees,\n'
printf '                         render.yaml, root scripts/ (shell included).\n'
printf '  Why all five           same reason tests count: without them the product\n'
printf '                         is fragile and cannot move at speed with confidence.\n'
printf '  Not the team\x27s code   vendor/ third_party/ node_modules/ Pods/ Carthage/\n'
printf '                         .yarn/; *.min.js, *.pb.go, _pb2.py, *.g.dart,\n'
printf '                         generated/; lockfiles; docs/ examples/ samples/ poc/;\n'
printf '                         AI-agent tooling (.agents/ prompts/); and whatever\n'
printf '                         .gitattributes marks linguist-vendored, -generated\n'
printf '                         or -documentation.\n'
printf '  Reported, not counted  .css .scss .html and code under assets/ (drawings\n'
printf '                         such as SVG wrapped as TSX) — the UI-assets line\n'
printf '  Excluded formats       data and prose (.json .toml .xml .md .txt .snap),\n'
printf '                         shell outside root scripts/, other YAML.\n'
printf '  Excluded folders       anything .gitignored\n'
printf '  Authors                the author map (%s): each git\n' "${AUTHOR_FILE:+${AUTHOR_FILE##*/}}${AUTHOR_FILE:-none found}"
printf '                         identity to a person and a role. Managers and\n'
printf '                         excluded contributors keep their lines in the team\n'
printf '                         total but are out of headcount, engineer-days and\n'
printf '                         cost; bots, and every [bot] account, are dropped.\n'
printf '  Engineer-days          every commit counts as effort: a date two people\n'
printf '                         both committed on is one coding day and two\n'
printf '                         engineer-days — that is why they differ\n'
printf '  Team multiplier        %s\n' "$([[ "${LOC_TEAM_ONLY:-1}" = 1 ]] && echo 'team lines ÷ (baseline × engineer-days), as the headline' || echo 'contribution-weighted mean of the author multipliers')"
printf '  Comment rule           // and /* */ in the C family (C, C++, Objective-C,\n'
printf '                         Swift, Go, Rust, Java, Kotlin, C#, JS/TS, shaders);\n'
printf '                         // in Zig; # in Python, Ruby, YAML, Dockerfiles,\n'
printf '                         Make, CMake; both in Terraform, Nix, PHP; -- in Lua\n'
printf '                         and Haskell. Python docstrings count as code: a\n'
printf '                         single line cannot tell it sits in one.\n'
printf '  ═══════════════════════════════════════════════════════════\n'

# ---- HTML report data -----------------------------------------------------
# The page is loc-report.html, beside this script. It reads window.LOC_DATA
# from a SIBLING loc-data.js — a <script src>, so it works over file:// with no
# server — and the data stays in .git/loc/, never committed. So every run puts
# a fresh COPY of the page beside the data. Never a symlink: macOS `open` resolves the link, the browser
# loads the repo path, and the page finds no loc-data.js beside it (2026-09-11:
# the report opened on "No data").
DATA_JS="$OUT_DIR/loc-data.js"
REPORT_HTML="$OUT_DIR/loc-report.html"
REPORT_PAGE="$SCRIPT_DIR/loc-report.html"
# Commit types ride in column 8 as "feat:3,fix:1"; the JSON carries them raw and
# the page folds them into its five categories.
DAYS_JSON=$(echo "$ROWS" | awk -F'\t' -v authors="$AUTHORS" -v base="$BASELINE_PER_DAY" '
  function mraw(loc, engdays,   m) { m = (engdays>0 ? loc/(base*engdays) : 0); if (m<0) m=0; return m }
  function tjson(list,   n, P, i, kv, out) { n=split(list, P, ","); out=""
    for (i=1;i<=n;i++) { if (P[i]=="") continue; split(P[i], kv, ":"); out=out (out==""?"":",") "\"" kv[1] "\":" kv[2] }
    return "{" out "}" }
  BEGIN { n=split(authors, A, ";") }
  { d=$1; a=$2; if (!(d in days)) { days[d]; D[++m]=d }
    c[d]+=$7; if (a=="bot") next;
    # managers ("staff"): their commits and lines count for the team; no headcount
    if (a=="staff") { hc[d]+=$7; dtot[d]+=$3+$4; ndtot[d]+=$5+$6; next }
    cm[d,a]+=$7; hc[d]+=$7; ty[d,a]=$8;
    pn=split($8, P, ","); for (pi=1;pi<=pn;pi++) if (P[pi]!="") { split(P[pi], kv, ":"); tt[d,kv[1]]+=kv[2]; if (!((d,kv[1]) in tk)) { tk[d,kv[1]]; tl[d]=tl[d] (tl[d]==""?"":",") kv[1] } }
    loc[d,a]+=$3+$4; has[d,a]=1; dtot[d]+=$3+$4;
    nloc[d,a]+=$5+$6; ndtot[d]+=$5+$6;
    if ($7>0 && !((d,a) in seen)) { seen[d,a]; h[d]++ } }
  END {
    printf "[";
    for (k=1;k<=m;k++) { d=D[k]; if (k>1) printf ",";
      printf "{\"date\":\"%s\",\"commits\":%d,\"humanCommits\":%d,\"humans\":%d,\"by\":{", d, c[d], hc[d]+0, h[d]+0;
      first=1; num=0; den=0; nnum=0; nden=0;
      for (i=1;i<=n;i++) { a=A[i]; if (!((d,a) in has)) continue;
        if (!first) printf ","; first=0;
        printf "\"%s\":{\"commits\":%d,\"loc\":%d,\"mult\":%.2f,\"ncloc\":%d,\"nmult\":%.2f,\"types\":%s}", a, cm[d,a], loc[d,a], mraw(loc[d,a],1), nloc[d,a], mraw(nloc[d,a],1), tjson(ty[d,a]);
        w=loc[d,a]; if (w<0) w=0; num+=mraw(w,1)*w; den+=w
        nw=nloc[d,a]; if (nw<0) nw=0; nnum+=mraw(nw,1)*nw; nden+=nw }
      tl2=""; tn=split(tl[d], TK, ","); for (ti=1;ti<=tn;ti++) if (TK[ti]!="") tl2=tl2 (tl2==""?"":",") TK[ti] ":" tt[d,TK[ti]];
      printf "},\"team\":{\"commits\":%d,\"loc\":%d,\"mult\":%.2f,\"ncloc\":%d,\"nmult\":%.2f,\"types\":%s}", hc[d]+0, dtot[d], (den>0 ? num/den : 0), ndtot[d], (nden>0 ? nnum/nden : 0), tjson(tl2);
      printf "}" }
    printf "]" }')
AUTHORS_JSON=$(echo "$AUTHOR_ROWS" | awk -F'\t' -v base="$BASELINE_PER_DAY" '
  { m=($5>0 ? $2/(base*$5) : 0); if (m<0) m=0; nm=($5>0 ? $3/(base*$5) : 0); if (nm<0) nm=0;
    if (NR>1) printf ",";
    printf "{\"name\":\"%s\",\"loc\":%d,\"ncloc\":%d,\"commits\":%d,\"days\":%d,\"mult\":%.2f,\"nmult\":%.2f,\"since\":\"%s\"}", $1, $2, $3, $4, $5, m, nm, $6 }')
AUTHOR_ORDER_JSON=$(echo "$AUTHORS" | awk -F';' '{ for (i=1;i<=NF;i++) { if (i>1) printf ","; printf "\"%s\"", $i } }')
cat > "$DATA_JS" <<EOF
window.LOC_DATA = {
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repo": "$(basename "$PWD")",
  "head": "$(git rev-parse --short HEAD 2>/dev/null)",
  "baselinePerDay": $BASELINE_PER_DAY,
  "startDate": "${LOC_START_DATE:-}",
  "teamOnly": $([[ "${LOC_TEAM_ONLY:-1}" = 1 ]] && echo true || echo false),
  "cost": {"annual": ${LOC_COST_ANNUAL:-150000}, "currency": "${LOC_COST_CURRENCY:-AUD}", "workDays": ${LOC_WORK_DAYS:-220}},
  "cache": {"state": "$CACHE_STATE", "frozenThrough": "${CACHE_LAST:-}"},
  "authorOrder": [$AUTHOR_ORDER_JSON],
  "authors": [$AUTHORS_JSON],
  "team": {"commits": $(echo "$AUTHOR_ROWS" | awk -F'\t' '{s+=$4} END{print s+0}'), "loc": $HIST_TOTAL, "ncloc": $HIST_TOTAL_N, "engDays": $ENG_DAYS_ACTUAL, "mult": $HIST_MULT, "nmult": $HIST_MULT_N},
  "days": $DAYS_JSON,
  "workspaces": [$WS_JSON],
  "languages": [$LANG_JSON],
  "tree": {"total": $TOTAL, "product": $PROD, "test": $TEST, "config": $CONFIG, "pipeline": $PIPELINE, "infra": $INFRA,
           "ui": $UI, "history": $HIST_TOTAL, "historyCommits": $HIST_COMMITS,
           "ncloc": $TOTAL_N, "nclocProduct": $PROD_N, "nclocTest": $TEST_N, "nclocConfig": $CONFIG_N,
           "nclocPipeline": $PIPELINE_N, "nclocInfra": $INFRA_N, "nclocHistory": $HIST_TOTAL_N,
           "clean": $([[ "$CLONE_DIRTY" = 1 ]] && echo false || echo true)},
  "force": {"engineers": $HUMANS, "codingDays": $DAYS_ACTUAL, "engDays": $BASELINE_ENG_DAYS, "how": "$BASELINE_HOW", "baseline": $BASELINE, "mult": $MULT, "engDaysOut": $ENG_DAYS_OUT, "nmult": $MULT_N, "nclocEngDaysOut": $ENG_DAYS_OUT_N}
};
EOF
# rm first: a leftover symlink must become a real file, and cp would follow it
rm -f "$REPORT_HTML" && cp "$REPORT_PAGE" "$REPORT_HTML"
printf '\n  ▶  HTML report:  file://%s\n' "$REPORT_HTML"
printf '     data:         %s\n\n' "$DATA_JS"
# open it in the default browser (macOS `open`); LOC_NO_OPEN=1 suppresses
if [[ -z "${LOC_NO_OPEN:-}" ]] && command -v open >/dev/null 2>&1; then open "$REPORT_HTML" && echo '  (opened in your default browser)'; fi
