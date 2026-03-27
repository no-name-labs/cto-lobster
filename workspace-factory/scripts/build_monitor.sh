#!/usr/bin/env bash
# Build Monitor — runs every 5 min via crontab.
# Detects stalled/failed builds and notifies CTO via Telegram.
# No-op if no build running. Safe to run at any time.
set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
PROGRESS="$OPENCLAW_HOME/workspace-factory/.cto-brain/runtime/build_progress.json"
RUNTIME_DIR="$OPENCLAW_HOME/workspace-factory/.cto-brain/runtime"
FAILURE_FLAG="$RUNTIME_DIR/failure_notified"

# Exit silently if no progress file
[ ! -f "$PROGRESS" ] && exit 0

# Load env for openclaw CLI
if [ -f "$OPENCLAW_HOME/.env" ]; then
  set -a; . "$OPENCLAW_HOME/.env"; set +a
fi
export OPENCLAW_STATE_DIR="$OPENCLAW_HOME"
export OPENCLAW_CONFIG_PATH="$OPENCLAW_HOME/openclaw.json"

# Read progress fields
STATUS=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('status',''))" 2>/dev/null || echo "")
AGENT=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('agent_id','unknown'))" 2>/dev/null)
STEP=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('current_step','?'))" 2>/dev/null)
ELAPSED=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('elapsed_seconds',0))" 2>/dev/null)
UPDATED=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('updated_at',''))" 2>/dev/null)

# Resolve CTO Telegram target
CTO_TARGET=$(bash "$OPENCLAW_HOME/workspace-factory/scripts/resolve_cto_topic.sh" "$OPENCLAW_HOME" 2>/dev/null || echo "")
[ -z "$CTO_TARGET" ] && exit 0

send_msg() {
  openclaw message send --channel telegram --target "$CTO_TARGET" -m "$1" --json >/dev/null 2>&1 || true
}

# ── CASE 1: status=running ──────────────────────────────────────
if [ "$STATUS" = "running" ]; then
  # Check if lobster processes are alive
  ALIVE=$(ps aux 2>/dev/null | grep -v grep | grep -c "lobster" || echo "0")
  if [ "$ALIVE" -eq 0 ]; then
    # Processes dead but status=running → stalled
    MINS=$((ELAPSED / 60))
    send_msg "PIPELINE_STALLED agent_id=$AGENT elapsed=${MINS}m last_step=$STEP"
  fi
  # If alive → do nothing, lobster handles progress notifications
  exit 0
fi

# ── CASE 2: status=failed ──────────────────────────────────────
if [ "$STATUS" = "failed" ]; then
  # Check if we already notified about this failure
  if [ -f "$FAILURE_FLAG" ]; then
    # Already sent notification — skip
    exit 0
  fi

  # Check if updated_at is recent (within last 10 minutes)
  IS_RECENT=$(python3 -c "
import json, datetime, sys
try:
    d = json.load(open('$PROGRESS'))
    updated = d.get('updated_at', '')
    if not updated:
        print('no')
        sys.exit(0)
    ts = datetime.datetime.fromisoformat(updated.replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    diff = (now - ts).total_seconds()
    print('yes' if diff < 600 else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")

  if [ "$IS_RECENT" = "yes" ]; then
    WS="$OPENCLAW_HOME/workspace-$AGENT"
    send_msg "PIPELINE_FAILED step=$STEP error=build_failed agent_id=$AGENT workspace=$WS"
    # Create flag file to avoid duplicate notifications
    mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$FAILURE_FLAG"
  fi
  exit 0
fi
