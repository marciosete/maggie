#!/bin/bash
#
# Strict LOC accounting + force multiplier for the git repository it is run in.
#
# Counts the product surface in whatever languages the repository holds. Every
# path goes through one classifier (AWK_RULES below) that names its language
# and comment rule and puts it in one of four categories:
#   product    executable code in a programming language
#   test       code at a test path (tests/, __tests__/, *Tests/, .test., _test., test_*.py ...)
#   pipeline   CI/CD definitions (.github/, .gitlab-ci.yml, Jenkinsfile, fastlane/ ...)
#   infra      infrastructure as code (Terraform, Dockerfiles, compose, k8s/helm,
#              infra/ and deploy/ trees, render.yaml ...)
# The authoritative list is the Scope block the report prints.
# Excluded on purpose:
#   - vendored and generated code         (vendor/, third_party/, node_modules/, Pods/,
#                                          *.min.js, *.pb.go, linguist-vendored/-generated)
#   - lockfiles                           (*-lock.*, *.lock)
#   - build and tool configuration        (*.config.*, .*rc.js, build.gradle, Makefile,
#     and test setup                       build.zig, *.setup.*, conftest.py ...)
#   - docs/, examples/, samples/          (documentation, not the product)
#   - data and prose formats              (.json .toml .xml .md .txt, YAML outside
#                                          pipeline and infra, shell scripts)
#   - .css / .html                        (UI assets — reported separately, not counted)
#
# Functional code = product + test + pipeline + infra, aggregated into one count.
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
#   dates — an engineer who joins on day 40 adds 1 engineer-day, not 40. A
#   bot's lines (a coding agent's) are the team's output; a bot is in no
#   headcount and earns no engineer-day, like a manager.
#   A multiplier is floored at 0 — a net-deletion day is not negative output.
#
# Every git identity in history (email + name) is resolved to a person before
# anything is counted — see "identities" below — so one person's several emails
# and spellings are one engineer, and a bot is a bot however it signs.
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
#   LOC_LIST_AUTHORS=1     list every commit identity and the person it resolved to, then stop
#   LOC_AUTO_MERGE=1       how identities are merged into people (see "identities" below):
#                          1 = every rule, email = same email / noreply login / exact name, 0 = off
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

BASELINE_PER_DAY="${LOC_BASELINE:-150}"

# ---- what counts -----------------------------------------------------------
# One classifier for every path, in the working tree and in history alike, so
# the two always reconcile. classify(path) answers "category|language|comment
# style", "ui|..." for a UI asset (reported, never counted), or "" (excluded).
#
# The principles, whatever the language:
#   - Executable code in a programming language is product.
#   - Test code counts, at the paths each ecosystem keeps it: without tests the
#     product is fragile and cannot be moved at speed.
#   - Infrastructure as code and CI/CD pipelines count for the same reason: they
#     are what lets the product ship. They count when they are written as code or
#     as a pipeline/deployment definition — never a data manifest (.json .toml
#     .xml), a lockfile or app content.
#   - Build and tool configuration (*.config.*, .*rc.js, build.gradle, Makefile,
#     build.zig, Package.swift ...) and test setup (*.setup.*, setupTests.*,
#     conftest.py) are not product code, and are excluded.
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
  # build and tool configuration, and test setup, are not product code: they set
  # up how the code is built, linted and tested (babel.config.js, jest.config.ts,
  # .eslintrc.js, build.gradle, Makefile, jest.setup.ts, conftest.py ...), wherever
  # they sit, a test folder included (2026-10-04)
  if (p ~ /\.(config|setup)\.[A-Za-z0-9]+$/ || p ~ /(^|\/)\.[A-Za-z0-9_-]+rc\.[cm]?[jt]s$/ \
      || p ~ /(^|\/)(setupTests|conftest)\.[A-Za-z]+$/ \
      || p ~ /(^|\/)(Makefile|GNUmakefile|makefile|CMakeLists\.txt|Justfile|justfile|Rakefile|Gemfile|Podfile|Brewfile|Dangerfile|build\.zig|Package\.swift|setup\.py|noxfile\.py|build\.rs|BUILD|BUILD\.bazel|WORKSPACE|WORKSPACE\.bazel|MODULE\.bazel|[Gg]ulpfile\.[cm]?[jt]s|Gruntfile\.[cm]?[jt]s)$/ \
      || p ~ /\.(gradle|gradle\.kts|cmake|mk|bzl|nix|gemspec)$/) return ""
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
      || p ~ /\.(test|spec)\.[^\/]*$/ || p ~ /_(test|tests|spec|unittest)\.[A-Za-z0-9]+$/ \
      || p ~ /(^|\/)test_[^\/]*\.py$/ \
      || p ~ /(Test|Tests|Spec|Specs)\.(java|kt|kts|scala|swift|cs|php|groovy|m|mm)$/) cat = "test"
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
# "bot" is the reserved name: its lines count for the team, it is in no author
# table, headcount or engineer-day. Bot accounts are recognised without a map
# entry (see "identities").
# Set LOC_AUTHOR_MAP to merge one person's several emails into one name, e.g.
#   LOC_AUTHOR_MAP='ann@work.com=Ann Lee;ann@home.com=Ann Lee;release-bot@acme.com=bot'
AUTHOR_MAP="${LOC_AUTHOR_MAP:-}"
# The author map: one git identity (its author NAME) per line, tab-separated:
#   identity  person  role  evidence
# role: engineer | tester (both counted as engineers) | manager or excluded (their
# lines count for the team; they are out of engineer counts, engineer-days and
# cost) | bot (lines for the team, no headcount). Keyed by name, so no email need be written down;
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

# ---- identities: who is who ---------------------------------------------
# One person commits under several git identities — a work and a home email, a
# GitHub noreply address, "jrieken" one day and "Johannes Rieken" the next —
# and keyed by name alone each spelling was its own engineer (2026-10-04: VS
# Code, 3,450 identities; "Johannes Rieken", "Johannes" and "jrieken" were three
# engineers with 2,308 engineer-days between them, and "Copilot" was a human
# with 259). So every identity in history is resolved to a person before
# anything is counted: union-find over the rules below, strongest first. The
# explicit map above wins over all of them. LOC_AUTO_MERGE picks the rules:
#   1 (default)  same email; the GitHub/GitLab noreply login; the same name
#                written differently (case, accents, punctuation, word order —
#                two words or more, so every "alex" is not one person); an
#                email whose local part spells a name seen in history
#                (first.last, firstlast, flast — six characters or more, and
#                only when exactly one name spells that way)
#   email        same email, the noreply login, and the exact name only
#   0            off: identity is the author name, as it was
# In every mode but 0 a one-word name never joins two emails — "Tim", "unknown"
# and "Ubuntu" are not one person — unless it is a GitHub login seen in history.
# A cluster holding one bot identity ([bot] accounts, dependabot, renovate,
# copilot, github-actions, anything ending in "bot") is a bot. A person is
# shown under the name with most commits, or under whatever the explicit map
# says for any member (so the map also names, excludes or drops a whole
# cluster with one line). The result is .git/loc/identities.tsv — email, name,
# person, commits, first, last — which LOC_LIST_AUTHORS=1 prints grouped by
# person, so a wrong merge is visible and one map line overrides it.
AUTO_MERGE="${LOC_AUTO_MERGE:-1}"
IDENTITIES="$OUT_DIR/identities.tsv"
git log --format='%aE%x09%aN%x09%ad' --date=short 2>/dev/null | LC_ALL=C awk -F'\t' -v mode="$AUTO_MERGE" -v amap="$AUTHOR_MAP" '
  function find(x) { while (par[x]!=x) { par[x]=par[par[x]]; x=par[x] } return x }
  function node(x) { if (!(x in par)) par[x]=x; return x }
  function join(a, b,   ra, rb) { ra=find(node(a)); rb=find(node(b)); if (ra!=rb) par[ra]=rb }
  # ASCII-fold enough of Latin-1 that "João" and "Joao" meet
  function fold(s,   i) { for (i=1;i<=nF;i++) if (index(s, FR[i])) gsub(FR[i], FT[i], s); return s }
  function norm(s) { s=tolower(fold(s)); gsub(/[^a-z0-9]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
  function sorted(s,   n, T, i, j, t, out) { n=split(s, T, " ")
    for (i=2;i<=n;i++) { t=T[i]; for (j=i-1; j>=1 && T[j]>t; j--) T[j+1]=T[j]; T[j+1]=t }
    out=""; for (i=1;i<=n;i++) out=out (i>1?" ":"") T[i]; return out }
  function login(e,   l) { if (e !~ /@users\.noreply\.(github|gitlab)\.com$/) return ""; l=e; sub(/@.*/, "", l); sub(/^[0-9]+[+-]/, "", l); return l }
  function localpart(e,   l) { l=e; sub(/@.*/, "", l); sub(/\+.*/, "", l); gsub(/[._-]/, "", l); return l }
  function isbot(e, n,   l) { l=e; sub(/@.*/, "", l)
    if (index(e, "[bot]") || index(n, "[bot]")) return 1
    if (l ~ /^(dependabot|renovate|greenkeeper|github-actions|semantic-release|copilot|snyk-bot|imgbot|allcontributors|mergify|codecov|pre-commit-ci|sonarcloud|whitesource|mend-)/) return 1
    if (n ~ /^(dependabot|renovate|greenkeeper|github-actions|semantic-release|copilot|snyk-bot|imgbot|allcontributors|mergify|codecov|pre-commit-ci|sonarcloud|whitesource|mend-)/) return 1
    if (l ~ /(^|[-_.])bot$/ || n ~ /(^|[ _-])bot$/) return 1
    return 0 }
  # a local-part form -> the one normalised name that spells it; two names, and it is ambiguous
  function form(f, key) { if (f=="" || length(f)<6) return; if ((f in idx) && idx[f]!=key) amb[f]=1; else idx[f]=key }
  BEGIN {
    nF=split("à a á a â a ã a ä a å a À a Á a Â a Ã a Ä a Å a è e é e ê e ë e È e É e Ê e Ë e ì i í i î i ï i Ì i Í i Î i Ï i ò o ó o ô o õ o ö o ø o Ò o Ó o Ô o Õ o Ö o Ø o ù u ú u û u ü u Ù u Ú u Û u Ü u ç c Ç c ñ n Ñ n ý y ÿ y Ý y ß ss", T, " ")
    for (i=1;i<=nF;i+=2) { FR[(i+1)/2]=T[i]; FT[(i+1)/2]=T[i+1] }; nF=nF/2
    n=split(amap, L, ";"); for (i=1;i<=n;i++) if (L[i]!="") { k=index(L[i],"="); key=substr(L[i],1,k-1); ex[(index(key,"@") ? "E:" tolower(key) : "N:" key)]=substr(L[i],k+1) } }
  { e=tolower($1); n=$2; k=e "\t" n
    if (!(k in c)) { K[++nk]=k; E[nk]=e; N[nk]=n; first[k]=$3; last[k]=$3 }
    c[k]++; if ($3<first[k]) first[k]=$3; if ($3>last[k]) last[k]=$3 }
  END {
    for (i=1;i<=nk;i++) { l=login(E[i]); if (l!="") logins[tolower(l)] }
    for (i=1;i<=nk;i++) { e=E[i]; n=N[i]; node("E:" e); node("N:" n)
      if (mode=="0") continue
      l=login(e); if (l!="") join("E:" e, "L:" tolower(l))
      nn=norm(n); t=split(nn, T, " ")
      # A one-word name ("Tim", "unknown", "Ubuntu") never joins two emails: it
      # bridges only when it is a GitHub login seen in history (2026-10-04: one
      # "unknown" pulled six strangers into one engineer; "Tim" was two people).
      if (t<2) { if (nn in logins) join("E:" e, "L:" nn); continue }
      join("E:" e, "N:" n)
      if (mode=="email") continue
      key="n:" sorted(nn); join("N:" n, key)
      f=nn; gsub(/ /, "", f); form(f, key); form(T[1] T[t], key); form(substr(T[1],1,1) T[t], key) }
    if (mode!="0" && mode!="email")
      for (i=1;i<=nk;i++) { e=E[i]; if (login(e)!="") continue; l=localpart(e); if ((l in idx) && !(l in amb)) join("E:" e, idx[l]) }
    # cluster facts: bot; display name (most commits, a multi-word name before a
    # handle: "Isidor Nikolic" over "isidor"); explicit person (most commits)
    for (i=1;i<=nk;i++) { k=K[i]; r=(mode=="0") ? find("N:" N[i]) : find("E:" E[i])
      if (isbot(E[i], tolower(fold(N[i])))) bot[r]=1
      w=(split(norm(N[i]), T, " ")>=2) ? 2 : 1
      nm[r SUBSEP N[i]]+=c[k]
      if (w > rank[r]+0 || (w == rank[r]+0 && nm[r SUBSEP N[i]] > best[r]+0)) { rank[r]=w; best[r]=nm[r SUBSEP N[i]]; disp[r]=N[i] }
      em[r SUBSEP E[i]]+=c[k]; if (em[r SUBSEP E[i]] > beste[r]+0) { beste[r]=em[r SUBSEP E[i]]; demail[r]=E[i] }
      x = (("E:" E[i]) in ex) ? ex["E:" E[i]] : (("N:" N[i]) in ex) ? ex["N:" N[i]] : ""
      if (x!="" && (!(r in xp) || c[k] > expc[r])) { xp[r]=x; expc[r]=c[k] } }
    # Two people under one name ("unknown" four times over) must stay two
    # people downstream, where a person is its display string: the second and
    # later carry their email.
    for (i=1;i<=nk;i++) { r=(mode=="0") ? find("N:" N[i]) : find("E:" E[i]); if (!(r in rs)) { rs[r]; shared[disp[r]]++ } }
    for (r in rs) if (shared[disp[r]] > 1 && mode!="0") disp[r]=disp[r] " <" demail[r] ">"
    for (i=1;i<=nk;i++) { k=K[i]; r=(mode=="0") ? find("N:" N[i]) : find("E:" E[i])
      p = (("E:" E[i]) in ex) ? ex["E:" E[i]] : (("N:" N[i]) in ex) ? ex["N:" N[i]] : (r in xp) ? xp[r] : (r in bot) ? "bot" : disp[r]
      printf "%s\t%s\t%s\t%d\t%s\t%s\n", E[i], N[i], p, c[k], first[k], last[k] } }
' > "$IDENTITIES"
# total identities, people, identities folded into another, bot identities
IFS=$'\t' read -r ID_TOTAL ID_PEOPLE ID_MERGED ID_BOTS < <(awk -F'\t' '
  { n++; if ($3=="bot") b++; else if ($3=="staff") s++; else if (!($3 in p)) { p[$3]; np++ } }
  END { printf "%d\t%d\t%d\t%d\n", n, np, n-b-s-np, b }' "$IDENTITIES")

# LOC_LIST_AUTHORS=1: every identity and the person it resolved to, grouped by
# person, most commits first. The input for the author map.
if [[ -n "${LOC_LIST_AUTHORS:-}" ]]; then
  printf 'email\tname\tperson\tcommits\tfirst\tlast\n'
  sort -t$'\t' -k3,3 -k4,4nr "$IDENTITIES"
  printf '\n%s identities -> %s people, %s bot identities; %s identities merged into a person (LOC_AUTO_MERGE=%s)\n' "$ID_TOTAL" "$ID_PEOPLE" "$ID_BOTS" "$ID_MERGED" "$AUTO_MERGE" >&2
  exit 0
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
# LC_ALL=C: in a UTF-8 locale BSD awk aborts on the first byte it cannot decode
# ("towc: multibyte conversion failure") and the rest of that batch is never
# counted (2026-10-04: one UTF-16 test fixture in VS Code lost 3,211 files and
# 770k lines from the tree, so history and tree were 27% apart). Bytes are
# enough here: the comment rule is ASCII.
PER_FILE=$(printf '%s\n' "$CLASSIFIED" | cut -f1 | grep . | sed 's|^|./|' | tr '\n' '\0' \
  | LC_ALL=C xargs -0 awk "$AWK_RULES"'
    function out() { if (f != "") printf "%s\t%d\t%d\n", substr(f, 3), raw, code }
    FNR == 1 { out(); f = FILENAME; split(langOf(f), LS, "|"); style = LS[2]; raw = 0; code = 0 }
    { raw++; if (isCode($0, style)) code++ }
    END { out() }' 2> "$OUT_DIR/count.err")
# Never silent: a batch that dies takes its remaining files with it.
if [[ -s "$OUT_DIR/count.err" ]]; then
  printf '  ! line counting: awk stopped on a file; a batch of files may be uncounted and the run will not reconcile:\n' >&2
  sed 's/^/      /' "$OUT_DIR/count.err" | head -5 >&2
fi

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
IFS=$'\t' read -r PIPELINE PIPELINE_N <<< "$(tree_sum CAT pipeline)"
IFS=$'\t' read -r INFRA INFRA_N <<< "$(tree_sum CAT infra)"
IFS=$'\t' read -r UI _ <<< "$(tree_sum CAT ui)"
TOTAL=$((PROD + TEST + PIPELINE + INFRA)); TOTAL_N=$((PROD_N + TEST_N + PIPELINE_N + INFRA_N))
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
  } 2>/dev/null | LC_ALL=C awk -F'\t' -v since="$since" -v first="$FIRST_DAY" "$AWK_RULES"'
    # The Conventional Commits type of a subject ("fix(harness)!: ..." -> fix);
    # anything else (a merge, a free-form message) is "other".
    function ctype(subj,   t) { if (match(subj, /^[a-z]+(\([^)]*\))?!?:/)) { t=substr(subj, 1, RLENGTH); sub(/[(!:].*$/, "", t); return t } return "other" }
    # "feat:3,fix:1" -> one more of t
    function tally(list, t,   n, P, i, kv, out, hit) { n=split(list, P, ","); out=""; hit=0
      for (i=1;i<=n;i++) { if (P[i]=="") continue; split(P[i], kv, ":"); if (kv[1]==t) { kv[2]++; hit=1 }; out=out (out==""?"":",") kv[1] ":" kv[2] }
      return hit ? out : out (out==""?"":",") t ":1" }
    # The raw identity, "email<US>name": rows are resolved to people after the
    # walk (see "identities"), so a cached row never depends on any map.
    function author(email, name) { return tolower(email) "\037" name }
    # The path in a ---/+++ header. Git ends the header with a tab when the path
    # holds a space (2026-10-04: every Swift file under "App Intents/" was
    # dropped, 19k lines), and quotes a path holding a quote or a backslash.
    function hdrpath(s, side) {
      sub(/\t$/, "", s)
      if (substr(s,1,1)=="\"" && substr(s,length(s),1)=="\"") { s=substr(s,2,length(s)-2); gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s) }
      if (substr(s,1,2)==side) s=substr(s,3)
      return s }
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
            printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n", parts[1], parts[2],
              (praw[k]+0), (traw[k]+0), (pcode[k]+0), (tcode[k]+0), (commits[k]+0), types[k] } }
  ' | sort
  rm -f "$attrs"
}
commits_through() { git log --pretty=%ad --date=short 2>/dev/null | awk -v d="$1" '$1<=d' | wc -l | tr -d ' '; }

# Keyed on what a cached row depends on — the walk itself, the classifier and
# per-line rule, the .gitattributes linguist markers — never on the whole
# script, so an edit to the report or the publish step keeps the cache warm.
# Rows hold raw identities, so neither the author map nor a new contributor
# (who may merge an old identity into a new person) touches the cache.
CACHE_KEY=$( { declare -f day_rows add_linguist_history; printf '%s\n' "$AWK_RULES" "$LINGUIST_SIG" "$FIRST_DAY"; } | shasum | cut -c1-12)

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

# Resolve each (day, identity) row to its (day, person) row — sums, and the
# commit-type tallies merged. Bots stay, as "bot": a coding agent's lines are
# in the tree, so they are the team's output (2026-10-04: VS Code, 21k lines
# by Copilot; dropping them left history 0.5% short of the tree); like "staff"
# a bot is in no headcount and earns no engineer-day. An identity the walk saw
# but the resolver did not (it cannot happen: both read the same log) keeps
# its name.
ROWS=$(echo "$ROWS" | awk -F'\t' -v idfile="$IDENTITIES" '
  function tally_add(list, t, by,   n, P, i, kv, out, hit) { n=split(list, P, ","); out=""; hit=0
    for (i=1;i<=n;i++) { if (P[i]=="") continue; split(P[i], kv, ":"); if (kv[1]==t) { kv[2]+=by; hit=1 }; out=out (out==""?"":",") kv[1] ":" kv[2] }
    return hit ? out : out (out==""?"":",") t ":" by }
  function tally_merge(a, b,   n, P, i, kv) { n=split(b, P, ","); for (i=1;i<=n;i++) { if (P[i]=="") continue; split(P[i], kv, ":"); a=tally_add(a, kv[1], kv[2]) }; return a }
  BEGIN { while ((getline l < idfile) > 0) { split(l, F, "\t"); m[F[1] "\037" F[2]]=F[3] } }
  { split($2, I, "\037"); p=($2 in m) ? m[$2] : I[2]
    k=$1 "\t" p; if (!(k in seen)) { seen[k]; KEYS[++n]=k }
    a[k]+=$3; b[k]+=$4; c[k]+=$5; d[k]+=$6; cm[k]+=$7; ty[k]=tally_merge(ty[k], $8) }
  END { for (i=1;i<=n;i++) { k=KEYS[i]; printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\n", k, a[k], b[k], c[k], d[k], cm[k], ty[k] } }' | sort)

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
    c[d]+=$7; if (a=="bot") { dtot[d]+=$3+$4; next }        # a coding agent: lines for the team, no human commit, no headcount
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
    print "  COMMITS = the day total; CMT = that author. Bots: lines in TEAM, no CMT, no headcount."; print ""
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

printf '  BY AUTHOR (net functional LOC, from git history; bots excluded; identities resolved to people)\n'
printf '  %s git identities → %s people and %s bot identities; %s identities merged into a person they share\n' "$ID_TOTAL" "$ID_PEOPLE" "$ID_BOTS" "$ID_MERGED"
printf '  an email, login or name with (LOC_AUTO_MERGE=%s; LOC_LIST_AUTHORS=1 lists every identity and its person)\n' "$AUTO_MERGE"
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

printf '  Functional LOC            %8s   (product + test + pipeline + infrastructure)\n' "$TOTAL"
printf '    product                 %8s   (executable code)\n' "$PROD"
printf '    test                    %8s   (code at a test path)\n' "$TEST"
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
printf '                         aggregated: product + test + pipeline +\n'
printf '                         infrastructure.\n'
printf '  Product                executable code. A scripts/ dir inside a package\n'
printf '                         IS that package.\n'
printf '  Test                   code at a test path: tests/ test/ spec/ __tests__/\n'
printf '                         *Tests/ *-tests/ e2e/ fixtures/; .test. .spec.;\n'
printf '                         _test. _spec.; test_*.py; *Test.java\n'
printf '                         *Tests.swift; Maestro flows (integration-tests/ YAML).\n'
printf '                         Tests inline in a source file (Zig, Rust) count as\n'
printf '                         product: a line has no path of its own.\n'
printf '  Pipeline               CI/CD: .github/ .gitlab-ci.yml .circleci/ Jenkinsfile\n'
printf '                         .buildkite/ azure-pipelines fastlane/ and the like.\n'
printf '  Infrastructure         Terraform/HCL, Dockerfiles, compose, k8s/helm,\n'
printf '                         infra/ deploy/ terraform/ cdk/ pulumi/ trees,\n'
printf '                         render.yaml, root scripts/ (shell included).\n'
printf '  Why all four           same reason tests count: without them the product\n'
printf '                         is fragile and cannot move at speed with confidence.\n'
printf '  Not product code       build and tool configuration: *.config.*, .*rc.js,\n'
printf '                         *.gradle, Makefile, CMake, build.zig, Package.swift,\n'
printf '                         Nix, Bazel, setup.py, build.rs, Gemfile, Podfile;\n'
printf '                         test setup: *.setup.*, setupTests.*, conftest.py.\n'
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
printf '  Identities             every git identity (email + name) resolved to a\n'
printf '                         person before counting: same email, GitHub noreply\n'
printf '                         login, the same name written differently, an email\n'
printf '                         that spells a name (LOC_AUTO_MERGE=%s). A cluster with\n' "$AUTO_MERGE"
printf '                         a bot identity is a bot. LOC_LIST_AUTHORS=1 shows it.\n'
printf '  Authors                the author map (%s): each git\n' "${AUTHOR_FILE:-none found}"
printf '                         identity to a person and a role, overriding the\n'
printf '                         automatic merge for that identity and naming its\n'
printf '                         whole cluster. Managers and excluded contributors\n'
printf '                         keep their lines in the team total but are out of\n'
printf '                         headcount, engineer-days and cost; a bot likewise,\n'
printf '                         its lines (a coding agent\x27s) in the team total.\n'
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
# Names go into JSON strings: a quote or a backslash in one (2026-10-04: VS
# Code, 'Ken "2-Foot" Brownfield') broke the data file and the page opened on
# "No data".
DAYS_JSON=$(echo "$ROWS" | awk -F'\t' -v authors="$AUTHORS" -v base="$BASELINE_PER_DAY" '
  function jstr(s,   out, i, c) { out=""; for (i=1;i<=length(s);i++) { c=substr(s,i,1); out=out ((c=="\\" || c=="\"") ? "\\" c : c) } return out }
  function mraw(loc, engdays,   m) { m = (engdays>0 ? loc/(base*engdays) : 0); if (m<0) m=0; return m }
  function tjson(list,   n, P, i, kv, out) { n=split(list, P, ","); out=""
    for (i=1;i<=n;i++) { if (P[i]=="") continue; split(P[i], kv, ":"); out=out (out==""?"":",") "\"" kv[1] "\":" kv[2] }
    return "{" out "}" }
  BEGIN { n=split(authors, A, ";") }
  { d=$1; a=$2; if (!(d in days)) { days[d]; D[++m]=d }
    c[d]+=$7; if (a=="bot") { dtot[d]+=$3+$4; ndtot[d]+=$5+$6; next }   # a coding agent: lines for the team, no human commit, no headcount
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
        printf "\"%s\":{\"commits\":%d,\"loc\":%d,\"mult\":%.2f,\"ncloc\":%d,\"nmult\":%.2f,\"types\":%s}", jstr(a), cm[d,a], loc[d,a], mraw(loc[d,a],1), nloc[d,a], mraw(nloc[d,a],1), tjson(ty[d,a]);
        w=loc[d,a]; if (w<0) w=0; num+=mraw(w,1)*w; den+=w
        nw=nloc[d,a]; if (nw<0) nw=0; nnum+=mraw(nw,1)*nw; nden+=nw }
      tl2=""; tn=split(tl[d], TK, ","); for (ti=1;ti<=tn;ti++) if (TK[ti]!="") tl2=tl2 (tl2==""?"":",") TK[ti] ":" tt[d,TK[ti]];
      printf "},\"team\":{\"commits\":%d,\"loc\":%d,\"mult\":%.2f,\"ncloc\":%d,\"nmult\":%.2f,\"types\":%s}", hc[d]+0, dtot[d], (den>0 ? num/den : 0), ndtot[d], (nden>0 ? nnum/nden : 0), tjson(tl2);
      printf "}" }
    printf "]" }')
AUTHORS_JSON=$(echo "$AUTHOR_ROWS" | awk -F'\t' -v base="$BASELINE_PER_DAY" '
  function jstr(s,   out, i, c) { out=""; for (i=1;i<=length(s);i++) { c=substr(s,i,1); out=out ((c=="\\" || c=="\"") ? "\\" c : c) } return out }
  { m=($5>0 ? $2/(base*$5) : 0); if (m<0) m=0; nm=($5>0 ? $3/(base*$5) : 0); if (nm<0) nm=0;
    if (NR>1) printf ",";
    printf "{\"name\":\"%s\",\"loc\":%d,\"ncloc\":%d,\"commits\":%d,\"days\":%d,\"mult\":%.2f,\"nmult\":%.2f,\"since\":\"%s\"}", jstr($1), $2, $3, $4, $5, m, nm, $6 }')
AUTHOR_ORDER_JSON=$(echo "$AUTHORS" | awk -F';' '
  function jstr(s,   out, i, c) { out=""; for (i=1;i<=length(s);i++) { c=substr(s,i,1); out=out ((c=="\\" || c=="\"") ? "\\" c : c) } return out }
  { for (i=1;i<=NF;i++) { if (i>1) printf ","; printf "\"%s\"", jstr($i) } }')
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
  "identities": {"total": $ID_TOTAL, "people": $ID_PEOPLE, "merged": $ID_MERGED, "bots": $ID_BOTS, "mode": "$AUTO_MERGE"},
  "authorOrder": [$AUTHOR_ORDER_JSON],
  "authors": [$AUTHORS_JSON],
  "team": {"commits": $(echo "$AUTHOR_ROWS" | awk -F'\t' '{s+=$4} END{print s+0}'), "loc": $HIST_TOTAL, "ncloc": $HIST_TOTAL_N, "engDays": $ENG_DAYS_ACTUAL, "mult": $HIST_MULT, "nmult": $HIST_MULT_N},
  "days": $DAYS_JSON,
  "workspaces": [$WS_JSON],
  "languages": [$LANG_JSON],
  "tree": {"total": $TOTAL, "product": $PROD, "test": $TEST, "pipeline": $PIPELINE, "infra": $INFRA,
           "ui": $UI, "history": $HIST_TOTAL, "historyCommits": $HIST_COMMITS,
           "ncloc": $TOTAL_N, "nclocProduct": $PROD_N, "nclocTest": $TEST_N,
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
