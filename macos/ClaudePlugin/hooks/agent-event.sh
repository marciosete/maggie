#!/bin/sh
# Hands one Claude Code hook event to Maggie: the JSON Claude Code passes on stdin
# goes into a file of its own in the directory Maggie names in MAGGIE_AGENT_EVENTS,
# which the app watches. It is written under a hidden name and then renamed, so the
# app never reads half an event. Outside Maggie the variable is unset and this does
# nothing. It never fails the hook: Claude Code goes on whatever happens here.

dir=$MAGGIE_AGENT_EVENTS
[ -n "$dir" ] || exit 0
mkdir -p "$dir" 2>/dev/null || exit 0
tmp=$(mktemp "$dir/.event.XXXXXX" 2>/dev/null) || exit 0
if cat > "$tmp" && mv "$tmp" "$dir/$(date +%s)-$$.json" 2>/dev/null; then
    exit 0
fi
rm -f "$tmp"
exit 0
