# Changelog

## 0.1.0 — 2026-06-24

Initial release.

- `scripts/send-mirrored.sh`: send a message via `openclaw message send … --json`,
  then append one `delivery-mirror` assistant row to the owning agent's current
  session transcript (resolved from `agents/<agent>/sessions/sessions.json` →
  `sessionFile`, so it follows compaction rotation).
- Row shape matches what OpenClaw core already writes for agentTurn cron
  delivery (`provider: "openclaw"`, `model: "delivery-mirror"`, zeroed usage,
  `stopReason: "stop"`), correctly `parentId`-chained to the last record. One
  extra `message.deliveryMirror.source` field is added for tracing.
- Session resolution: explicit `--session-key` → auto-constructed key
  (`group:<to>:topic:<thread>`, `group:<to>`, `direct:<to>`) → fallback scan of
  `sessions.json` matching `deliveryContext.to` / `route.target.to` + thread id.
- Optional `--idem <key>` idempotency guard (pre-send) against double delivery on
  cron retry; state in `<openclaw-home>/delivery-mirror/state/<agent>.seen`.
- Best-effort mirror: a send never fails because of a mirror problem (exit 0 with
  a warning if the session can't be resolved).
- Advisory locking via Python `fcntl.flock` on `<sessionFile>.mirror.lock` (no
  `flock` binary dependency; portable to macOS).
- Flags: `--dry-run`, `--no-send` (mirror only), `--no-mirror` (send only),
  `--message-file` / stdin, `--openclaw-home`, `--openclaw-bin`.
