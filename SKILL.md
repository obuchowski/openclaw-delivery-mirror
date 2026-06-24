---
name: delivery-mirror
description: Deliver a message from a cron/script via OpenClaw, then mirror it into the owning agent's session transcript so the agent remembers it sent it.
metadata: {"openclaw":{"emoji":"🪞","homepage":"https://github.com/obuchowski/openclaw-delivery-mirror","os":["linux","darwin"],"requires":{"bins":["bash","python3"]}}}
---

# delivery-mirror

A deterministic, **no-core-changes** helper for the gap between *delivering* a
message and the agent *remembering* it.

All commands: `bash "{baseDir}/scripts/send-mirrored.sh" <flags>`

## The problem

`--command` crons and external scripts call `openclaw message send …` directly.
The message reaches the chat — but it **bypasses the agent's run loop**, so the
agent's session JSONL never records it. Next time that agent wakes in the
chat/topic, it has no idea the message was ever sent. Classic case: calendar
agenda dispatchers and reminder scripts whose sessions run with
`delivery.mode: none` and send via CLI.

`agentTurn` crons don't have this problem — the OpenClaw delivery layer already
writes a `delivery-mirror` row for them. This skill gives the same continuity to
plain `--command` / script senders, **without touching OpenClaw core**.

## What it does

1. Sends the message exactly as before (`openclaw message send … --json`).
2. On success, resolves the owning agent's current session file from
   `agents/<agent>/sessions/sessions.json` (`.sessionFile` — follows compaction
   rotation).
3. Appends one `delivery-mirror` assistant row to that transcript — the **same
   row type** OpenClaw already writes for agentTurn cron delivery
   (`provider: "openclaw"`, `model: "delivery-mirror"`, zeroed usage,
   `stopReason: "stop"`), correctly `parentId`-chained to the last record.
4. Optional idempotency: `--idem <key>` skips the whole op if that key was
   already handled (guards against double-delivery on cron retry).

Mirroring is **best-effort**: if the session can't be resolved, delivery still
succeeded and the helper exits 0 with a warning — it never fails a send because
of a mirror problem.

## Why a skill, not a plugin

A true runtime plugin would mean changing/extending OpenClaw core. This stays a
self-contained script you drop next to your other command-cron scripts, so it
works on any OpenClaw host and upgrades independently.

## Usage

```bash
scripts/send-mirrored.sh \
  --agent ula \                       # agent id that owns the session (sessions dir)
  --account ula \                     # channel account for send (defaults to --agent)
  --to -1003971971641 \               # telegram chat id
  --thread-id 131 \                   # telegram forum topic (omit for non-forum)
  --source agenda-dispatch \          # label for logs / tracing
  --idem "agenda:131:$(date +%F):morning" \  # optional dedupe key
  --message "$MSG"
```

Message input: `--message "…"`, `--message-file PATH`, or `--message-file -`
(stdin).

### In a `--command` cron

Replace a bare `openclaw message send …` with:

```bash
/home/opc/.openclaw/skills/delivery-mirror/scripts/send-mirrored.sh \
  --agent ula --account ula --to -1003971971641 --thread-id 131 \
  --source agenda-dispatch --message "$MSG"
```

### Flags

| flag | meaning |
|------|---------|
| `--message` / `--message-file` | message text (file or `-` for stdin) |
| `--to` | channel target (telegram chat id) — required |
| `--agent` | agent id owning the session — required |
| `--account` | channel account id for send (default: `--agent`) |
| `--channel` | channel (default `telegram`) |
| `--thread-id` | telegram forum topic id |
| `--session-key` | explicit session key (else auto-resolved) |
| `--source` | label for logs / `deliveryMirror.source` |
| `--idem` | idempotency key; skip if already handled (exit 3) |
| `--openclaw-home` | OpenClaw home (default `$OPENCLAW_HOME` or `~/.openclaw`) |
| `--openclaw-bin` | openclaw binary (default `openclaw` on PATH) |
| `--dry-run` | print the plan, do nothing |
| `--no-send` | mirror only (testing) |
| `--no-mirror` | send only (= plain send) |

### Exit codes

| code | meaning |
|------|---------|
| 0 | delivered (mirrored, or mirror skipped best-effort with warning) |
| 2 | bad usage / missing required args |
| 3 | idempotency: `--idem` key already handled, nothing done |
| 4 | send failed (nothing mirrored) |

## Session resolution

The helper finds the transcript by, in order: explicit `--session-key`;
auto-constructed key (`agent:<agent>:<channel>:group:<to>:topic:<thread>`, then
`:group:<to>`, then `:direct:<to>`); finally a scan of `sessions.json` matching
`deliveryContext.to` / `route.target.to` (substring on `--to`) + thread id.
It always appends to the entry's `sessionFile`, so it follows compaction
rotation automatically.

## Caveats (read before trusting it blindly)

- **JSONL-format coupling.** It appends to the agent's session transcript using
  the observed on-disk row shape. That format is stable in practice (it mirrors
  what core already writes) but is **not a public API** — re-verify after a major
  OpenClaw upgrade. The append adds one extra `message.deliveryMirror.source`
  field for tracing; unknown fields are ignored by the loader.
- **Concurrency.** Appends are serialized with `flock` on
  `<sessionFile>.mirror.lock`. The gateway may not take that lock, so avoid
  mirroring into a topic while its agent is actively mid-run; dispatcher-style
  schedules (agent idle) are the safe, intended case.
- **State.** Idempotency keys live in
  `<openclaw-home>/delivery-mirror/state/<agent>.seen`; log in
  `<openclaw-home>/delivery-mirror/mirror.log`.

## Test

```bash
scripts/send-mirrored.sh --dry-run  --agent X --to <chat> --thread-id <t> --message "hi"
scripts/send-mirrored.sh --no-send  --agent X --to <chat> --thread-id <t> --message "hi"  # mirror only
```
