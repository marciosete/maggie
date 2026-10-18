#!/usr/bin/env bash
#
# The build number of the oldest Maggie that may keep running, for the release
# workflow to put in the appcast (generate_appcast --critical-update-version).
# Sparkle compares build numbers and people read versions: fork/minimum-version
# names a version, and this resolves it to the commit count of its tag, which is
# how releases are numbered (fork/install.sh, .github/workflows/release.yml).
#
# Usage: fork/minimum-build.sh --version <being released> --build <its build>
#
# Prints "minimum_build=<n>", or "minimum_build=" when there is no minimum. The
# version named must be a release, or the one being released; anything else is
# an error, so a typo can't quietly ship an update nobody has to take.

set -euo pipefail

VERSION=""
BUILD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?}"; shift ;;
        --build) BUILD="${2:?}"; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "usage: $0 --version <v> --build <n>" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${MINIMUM_VERSION_FILE:-$ROOT/fork/minimum-version}"

minimum=""
[ -f "$FILE" ] && minimum="$(sed '/^[[:space:]]*#/d' "$FILE" | tr -d '[:space:]')"
minimum="${minimum#v}"

if [ -z "$minimum" ]; then
    echo "minimum_build="
elif [ "$minimum" = "$VERSION" ]; then
    echo "minimum_build=$BUILD"
elif git -C "$ROOT" rev-parse -q --verify "refs/tags/v$minimum^{commit}" >/dev/null; then
    echo "minimum_build=$(git -C "$ROOT" rev-list --count "v$minimum")"
else
    echo "error: fork/minimum-version names $minimum, which is neither a release nor the one being released ($VERSION)" >&2
    exit 1
fi
