#!/usr/bin/env bash
# Build a clean ClawHub bundle for the delivery-mirror skill and print the
# publish command. The bundle contains ONLY what the skill needs at runtime
# plus SECURITY.md/CHANGELOG.md (the clawscan note references them). README,
# this script, and docs/ are NOT shipped.
set -euo pipefail

SLUG="delivery-mirror"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$REPO_ROOT/$SLUG"

# Single source of truth: version = the newest "## X.Y.Z" header in CHANGELOG.md.
# sed -E is portable across GNU/BSD awk-free; avoids gawk-only match(...,arr).
VERSION="$(sed -nE 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$REPO_ROOT/CHANGELOG.md" | head -n 1)"
[ -n "$VERSION" ] || { echo "ERROR: no semver '## X.Y.Z' header in CHANGELOG.md" >&2; exit 1; }
# Changelog body = the newest section's bullet lines (header excluded, stops at next section).
CHANGELOG_BODY="$(awk '/^## /{n++; if(n>1) exit; next} n==1' "$REPO_ROOT/CHANGELOG.md" | sed '/^[[:space:]]*$/d')"

echo "Preparing ClawHub bundle (version $VERSION)..."
rm -rf "$OUT"
mkdir -p "$OUT"

cp "$REPO_ROOT/SKILL.md" "$OUT/"
cp -r "$REPO_ROOT/scripts" "$OUT/scripts"
cp "$REPO_ROOT/SECURITY.md" "$OUT/"
cp "$REPO_ROOT/CHANGELOG.md" "$OUT/"

echo "Created: $OUT"
ls -R "$OUT"
echo ""
CLAWSCAN_NOTE='After "openclaw message send" the helper appends ONE delivery-mirror JSONL row to the owning agent OWN session transcript (resolved via agents/<agent>/sessions/sessions.json -> sessionFile) to restore continuity for command-cron/script deliveries. It reads sessions.json and appends a single assistant row; it makes no network calls of its own, runs no model, and performs no destructive operations. Advisory fcntl.flock serializes the append.'

# Print a copy-paste-safe command. printf %q shell-quotes every arg, so the
# changelog body (which contains backticks and quotes) can never be executed or
# break quoting when pasted.
echo "Publish with:"
printf '  clawhub skill publish %q --slug %q --version %q \\\n' "$OUT" "$SLUG" "$VERSION"
printf '    --changelog %q \\\n' "$CHANGELOG_BODY"
printf '    --clawscan-note %q\n' "$CLAWSCAN_NOTE"
