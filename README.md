# OpenClaw delivery-mirror 🪞

**Deliver from a cron/script, and let the agent remember it.**

OpenClaw `--command` crons and external scripts that call
`openclaw message send` deliver to the chat just fine — but they **bypass the
agent's run loop**, so the message never lands in the agent's session
transcript. Next time that agent wakes in the chat/topic, it has no idea the
message was ever sent. Calendar agenda dispatchers, reminder pings, and
status notifiers all hit this.

Messages sent through OpenClaw's own delivery layer (agent replies,
isolated/cron `agentTurn` delivery) don't have this problem: that layer passes a
*mirror context*, so core calls `appendAssistantMessageToSessionTranscript` and
writes a `delivery-mirror` row. A plain `openclaw message send` from a script
passes no mirror context — and the CLI has no flag to set one — so nothing is
mirrored. This skill closes that one gap, **without touching OpenClaw core**.

## What it does

1. Sends the message exactly as before: `openclaw message send … --json`.
2. On success, resolves the owning agent's **current** session file from
   `agents/<agent>/sessions/sessions.json` (`.sessionFile` — follows
   compaction rotation).
3. Appends **one** `delivery-mirror` assistant row to that transcript — the
   same shape core produces via `appendAssistantMessageToSessionTranscript`
   (`provider: "openclaw"`, `model: "delivery-mirror"`, zeroed usage,
   `stopReason: "stop"`), `parentId`-chained to the last record, with the optional
   `openclawDeliveryMirror: {kind:"channel-final"}` marker core attaches on real
   deliveries. The append is newline-safe and serialized with an advisory lock.
4. Optional `--idem <key>`: skips the whole op if that key was already handled
   (guards against double-delivery on cron retry).

Mirroring is **best-effort**: if the session can't be resolved, delivery still
succeeded and the helper exits 0 with a warning. A send never fails because of
a mirror problem.

## Quick start

```
openclaw skills install @obuchowski/delivery-mirror
```

Then, in a `--command` cron or any script, replace a bare
`openclaw message send …` with:

```bash
bash scripts/send-mirrored.sh \
  --agent ula --account ula \
  --to -1003971971641 --thread-id 131 \
  --source agenda-dispatch \
  --message "$MSG"
```

## Commands & flags

```
bash scripts/send-mirrored.sh <flags>
```

| flag | meaning |
|---|---|
| `--message` / `--message-file` | message text (file, or `-` for stdin) |
| `--to` | channel target (e.g. Telegram chat id) — required |
| `--agent` | agent id owning the session — required |
| `--account` | channel account id for send (default: `--agent`) |
| `--channel` | channel (default `telegram`) |
| `--thread-id` | Telegram forum topic id |
| `--session-key` | explicit session key (else auto-resolved) |
| `--source` | label recorded in the helper log (not in the row) |
| `--idem` | idempotency key; skip if already handled (exit 3) |
| `--openclaw-home` | OpenClaw home (default `$OPENCLAW_HOME` or `~/.openclaw`) |
| `--openclaw-bin` | openclaw binary (default `openclaw` on PATH) |
| `--dry-run` | print the plan, do nothing |
| `--no-send` | mirror only (testing) |
| `--no-mirror` | send only (= plain send) |

| exit | meaning |
|---|---|
| 0 | delivered (mirrored, or mirror skipped best-effort with warning) |
| 2 | bad usage / missing required args |
| 3 | idempotency: `--idem` key already handled, nothing done |
| 4 | send failed (nothing mirrored) |

## Session resolution

Explicit `--session-key` → auto-constructed key
(`agent:<agent>:<channel>:group:<to>:topic:<thread>`, then `:group:<to>`, then
`:direct:<to>`) → fallback scan of `sessions.json` matching
`deliveryContext.to` / `route.target.to` (substring on `--to`) + thread id. It
always appends to the entry's `sessionFile`, so it follows compaction rotation.

## Caveats

- **Reproduces a core row from bash.** `delivery-mirror` is a first-class core
  concept (`appendAssistantMessageToSessionTranscript` / core's `isDeliveryMirror`
  predicate); the only coupling is that we hand-append the JSONL because no CLI or
  tool exposes that function. Re-verify after a major OpenClaw upgrade. See
  [SECURITY.md](SECURITY.md).
- **Concurrency.** Appends are serialized with an advisory `fcntl.flock`; the
  safe, intended case is dispatcher-style schedules when the agent is idle.
- **No network of its own, no model, no destructive ops.**

## Test

```bash
bash scripts/send-mirrored.sh --dry-run --agent X --to <chat> --thread-id <t> --message "hi"
bash scripts/send-mirrored.sh --no-send --agent X --to <chat> --thread-id <t> --message "hi"  # mirror only
```

## License & contributions

MIT. Issues and PRs welcome:
https://github.com/obuchowski/openclaw-delivery-mirror
