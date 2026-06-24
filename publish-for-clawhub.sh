#!/usr/bin/env bash
# Build a clean ClawHub bundle for the delivery-mirror skill and print the
# publish command. The bundle contains ONLY what the skill needs at runtime
# plus SECURITY.md/CHANGELOG.md (the clawscan note references them). README,
# this script, and docs/ are NOT shipped.
set -euo pipefail

SLUG="delivery-mirror"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$REPO_ROOT/$SLUG"

echo "Preparing ClawHub bundle..."
rm -rf "$OUT"
mkdir -p "$OUT"

cp "$REPO_ROOT/SKILL.md" "$OUT/"
cp -r "$REPO_ROOT/scripts" "$OUT/scripts"
cp "$REPO_ROOT/SECURITY.md" "$OUT/"
cp "$REPO_ROOT/CHANGELOG.md" "$OUT/"

echo "Created: $OUT"
ls -R "$OUT"
echo ""
echo "Publish with:"
cat <<EOF
  clawhub skill publish "$OUT" --slug $SLUG --version 1.0.0 \\
    --changelog "\$(sed -n '/^## /,/^## /p' "$REPO_ROOT/CHANGELOG.md" | head -n -1)" \\
    --clawscan-note 'After "openclaw message send" the helper appends ONE delivery-mirror JSONL row to the owning agent OWN session transcript (resolved via agents/<agent>/sessions/sessions.json -> sessionFile) to restore continuity for command-cron/script deliveries. It reads sessions.json and appends a single assistant row; it makes no network calls of its own, runs no model, and performs no destructive operations. Advisory fcntl.flock serializes the append.'
EOF
