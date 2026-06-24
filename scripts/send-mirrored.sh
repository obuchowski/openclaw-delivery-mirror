#!/usr/bin/env bash
# delivery-mirror — send a Telegram (or other channel) message via OpenClaw AND
# mirror the delivered text into the target session transcript, so the agent that
# "owns" that chat/topic sees the message in its own context on the next turn.
#
# WHY: `--command` crons and external scripts that call `openclaw message send`
# bypass the agent's run loop. The message reaches the chat, but the agent's
# session JSONL never records it — the agent has no memory it was ever sent.
# This helper appends a `delivery-mirror` assistant row (the same row type the
# OpenClaw delivery layer already writes for agentTurn cron delivery) so the
# transcript stays continuous. No OpenClaw core changes required.
#
# Subcommand-free; flags only. Example:
#   send-mirrored.sh \
#     --agent ula --account ula \
#     --to -1003971971641 --thread-id 131 \
#     --source agenda-dispatch \
#     --message "$MSG"
#
# Exit codes:
#   0  delivered (+ mirrored, or mirror skipped as best-effort with a warning)
#   2  bad usage / missing required args
#   3  idempotency: this --idem key was already handled, nothing done
#   4  send failed (nothing mirrored)
set -uo pipefail

# ---- defaults ---------------------------------------------------------------
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
CHANNEL="telegram"
ACCOUNT=""
AGENT=""
TO=""
THREAD=""
MESSAGE=""
MESSAGE_FILE=""
SESSION_KEY=""
SOURCE="script"
IDEM=""
DRY=0
NO_SEND=0
NO_MIRROR=0

usage() { sed -n '2,40p' "$0"; }

# ---- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --message)        MESSAGE="$2"; shift 2;;
    --message-file)   MESSAGE_FILE="$2"; shift 2;;
    --to)             TO="$2"; shift 2;;
    --channel)        CHANNEL="$2"; shift 2;;
    --account)        ACCOUNT="$2"; shift 2;;
    --agent)          AGENT="$2"; shift 2;;
    --thread-id)      THREAD="$2"; shift 2;;
    --session-key)    SESSION_KEY="$2"; shift 2;;
    --source)         SOURCE="$2"; shift 2;;
    --idem)           IDEM="$2"; shift 2;;
    --openclaw-home)  OPENCLAW_HOME="$2"; shift 2;;
    --openclaw-bin)   OPENCLAW_BIN="$2"; shift 2;;
    --dry-run)        DRY=1; shift;;
    --no-send)        NO_SEND=1; shift;;        # mirror only (testing)
    --no-mirror)      NO_MIRROR=1; shift;;      # send only (behaves like plain send)
    -h|--help)        usage; exit 0;;
    *) echo "delivery-mirror: unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

# message may come from --message-file or stdin ("-")
if [ -n "$MESSAGE_FILE" ]; then
  if [ "$MESSAGE_FILE" = "-" ]; then MESSAGE="$(cat)"; else MESSAGE="$(cat "$MESSAGE_FILE")"; fi
fi

# ---- validation -------------------------------------------------------------
[ -n "$MESSAGE" ] || { echo "delivery-mirror: --message (or --message-file) required" >&2; exit 2; }
[ -n "$TO" ]      || { echo "delivery-mirror: --to required" >&2; exit 2; }
[ -n "$AGENT" ]   || { echo "delivery-mirror: --agent required (agent id owning the session)" >&2; exit 2; }
[ -n "$ACCOUNT" ] || ACCOUNT="$AGENT"   # channel account defaults to agent id

SESSIONS_DIR="$OPENCLAW_HOME/agents/$AGENT/sessions"
SESSIONS_JSON="$SESSIONS_DIR/sessions.json"
STATE_DIR="$OPENCLAW_HOME/delivery-mirror/state"
LOG="$OPENCLAW_HOME/delivery-mirror/mirror.log"
mkdir -p "$STATE_DIR"
SEEN="$STATE_DIR/${AGENT}.seen"
touch "$SEEN"

log() { echo "[$(date -u +%FT%TZ)] $*" >>"$LOG" 2>/dev/null; }

# ---- idempotency (pre-send, avoids double delivery on retry) -----------------
if [ -n "$IDEM" ]; then
  if grep -qxF "$IDEM" "$SEEN" 2>/dev/null; then
    log "skip idem=$IDEM source=$SOURCE (already handled)"
    echo "delivery-mirror: idem '$IDEM' already handled, nothing to do" >&2
    exit 3
  fi
fi

# ---- dry run ----------------------------------------------------------------
if [ "$DRY" = "1" ]; then
  echo "----- DRY RUN -----"
  echo "channel : $CHANNEL"
  echo "account : $ACCOUNT"
  echo "to      : $TO"
  echo "thread  : ${THREAD:-<none>}"
  echo "agent   : $AGENT"
  echo "source  : $SOURCE"
  echo "idem    : ${IDEM:-<none>}"
  echo "session : ${SESSION_KEY:-<auto-resolve>}"
  echo "no-send : $NO_SEND   no-mirror: $NO_MIRROR"
  echo "--- message ---"
  printf '%s\n' "$MESSAGE"
  exit 0
fi

# ---- 1) send ----------------------------------------------------------------
if [ "$NO_SEND" != "1" ]; then
  send_args=( message send --channel "$CHANNEL" --account "$ACCOUNT" -t "$TO" -m "$MESSAGE" --json )
  [ -n "$THREAD" ] && send_args+=( --thread-id "$THREAD" )
  if ! out="$("$OPENCLAW_BIN" "${send_args[@]}" 2>&1)"; then
    log "SEND FAIL source=$SOURCE to=$TO thread=${THREAD:-} rc=$? out=${out//$'\n'/ }"
    echo "delivery-mirror: send failed: $out" >&2
    exit 4
  fi
  log "sent source=$SOURCE to=$TO thread=${THREAD:-}"
else
  log "no-send source=$SOURCE (mirror only)"
fi

# ---- 2) mirror into the session transcript (best-effort) --------------------
if [ "$NO_MIRROR" = "1" ]; then
  exit 0
fi

OC_MSG="$MESSAGE" \
OC_SESSIONS_JSON="$SESSIONS_JSON" \
OC_SESSION_KEY="$SESSION_KEY" \
OC_CHANNEL="$CHANNEL" OC_AGENT="$AGENT" OC_TO="$TO" OC_THREAD="$THREAD" \
OC_SOURCE="$SOURCE" \
python3 - <<'PY'
import os, sys, json, uuid, time, fcntl

sj_path = os.environ["OC_SESSIONS_JSON"]
key     = os.environ.get("OC_SESSION_KEY", "")
channel = os.environ["OC_CHANNEL"]
agent   = os.environ["OC_AGENT"]
to      = os.environ["OC_TO"]
thread  = os.environ.get("OC_THREAD", "")
msg     = os.environ["OC_MSG"]
source  = os.environ.get("OC_SOURCE", "script")

def warn(m): print(f"delivery-mirror: WARN mirror: {m}", file=sys.stderr)

try:
    with open(sj_path) as f:
        sessions = json.load(f)
except Exception as e:
    warn(f"cannot read sessions.json ({sj_path}): {e}; delivery ok, mirror skipped")
    sys.exit(0)

def candidate_keys():
    if key:
        yield key
        return
    # auto-construct the common Telegram grammars
    if thread:
        yield f"agent:{agent}:{channel}:group:{to}:topic:{thread}"
    yield f"agent:{agent}:{channel}:group:{to}"
    yield f"agent:{agent}:{channel}:direct:{to}"

entry = None
for k in candidate_keys():
    if k in sessions:
        entry = sessions[k]; break

# fall back: match by delivery target + thread across all entries
if entry is None:
    for k, v in sessions.items():
        if not isinstance(v, dict):
            continue
        dc = v.get("deliveryContext") or {}
        rt = (v.get("route") or {}).get("target") or {}
        dest = dc.get("to") or rt.get("to") or ""
        tid = dc.get("threadId")
        if tid is None:
            tid = (v.get("route") or {}).get("thread", {}).get("id")
        if str(to) in dest and (str(tid) == str(thread) if thread else tid in (None, "")):
            entry = v; break

if entry is None:
    warn(f"no session entry matched to={to} thread={thread or '-'}; delivery ok, mirror skipped")
    sys.exit(0)

session_file = entry.get("sessionFile")
if not session_file:
    warn("matched session has no sessionFile; delivery ok, mirror skipped")
    sys.exit(0)

# parentId = id of the last record currently in the transcript (linked list)
parent_id = None
try:
    with open(session_file, "rb") as f:
        last = None
        for line in f:
            line = line.strip()
            if line:
                last = line
        if last:
            parent_id = json.loads(last).get("id")
except FileNotFoundError:
    pass
except Exception as e:
    warn(f"could not read tail of {session_file}: {e}; appending with parentId=null")

now_ms = int(time.time() * 1000)
iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now_ms / 1000)) + f".{now_ms % 1000:03d}Z"

record = {
    "type": "message",
    "id": str(uuid.uuid4()),
    "parentId": parent_id,
    "timestamp": iso,
    "message": {
        "role": "assistant",
        "content": [{"type": "text", "text": msg}],
        "api": "openai-responses",
        "provider": "openclaw",
        "model": "delivery-mirror",
        "usage": {
            "input": 0, "output": 0, "total": 0,
            "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0,
            "cache": {"read": 0, "write": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0},
        },
        "stopReason": "stop",
        "timestamp": now_ms,
        "deliveryMirror": {"source": source},
    },
}

line = json.dumps(record, ensure_ascii=False) + "\n"
lock_path = session_file + ".mirror.lock"
try:
    lf = open(lock_path, "w")
    fcntl.flock(lf, fcntl.LOCK_EX)
    with open(session_file, "a", encoding="utf-8") as f:
        f.write(line)
    fcntl.flock(lf, fcntl.LOCK_UN)
    lf.close()
    print(f"delivery-mirror: mirrored into {session_file}", file=sys.stderr)
except Exception as e:
    warn(f"append failed for {session_file}: {e}; delivery ok")
    sys.exit(0)
PY
mirror_rc=$?

# ---- 3) record idempotency key (only after success path) --------------------
if [ -n "$IDEM" ]; then
  printf '%s\n' "$IDEM" >>"$SEEN"
fi

exit 0
