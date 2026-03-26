#!/usr/bin/env bash
# Build Monitor — runs every 5 min via crontab.
# Sends Telegram progress update if a build is active.
# No-op if no build running. Safe to run at any time.
set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
PROGRESS="$OPENCLAW_HOME/workspace-factory/.cto-brain/runtime/build_progress.json"

# Exit silently if no progress file
[ ! -f "$PROGRESS" ] && exit 0

# Read progress
STATUS=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('status',''))" 2>/dev/null || echo "")
[ "$STATUS" != "running" ] && exit 0

# Build is active — gather info
AGENT=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('agent_id','unknown'))" 2>/dev/null)
STEP=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('current_step','?'))" 2>/dev/null)
ELAPSED=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('elapsed_seconds',0))" 2>/dev/null)
DONE=$(python3 -c "import json; print(len(json.load(open('$PROGRESS')).get('completed_steps',[])))" 2>/dev/null)
UPDATED=$(python3 -c "import json; print(json.load(open('$PROGRESS')).get('updated_at','?'))" 2>/dev/null)

# Get workspace stats
WS="$OPENCLAW_HOME/workspace-$AGENT"
PY_COUNT=0
TEST_COUNT=0
if [ -d "$WS" ]; then
  PY_COUNT=$(find "$WS" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
  if [ -d "$WS/tests" ]; then
    TEST_COUNT=$(find "$WS/tests" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
  fi
fi

# Get Telegram target from CTO binding
CHAT_ID=$(python3 -c "
import json
d = json.load(open('$OPENCLAW_HOME/openclaw.json'))
for b in d.get('bindings', []):
    if b.get('agentId') == 'cto-factory':
        peer = b.get('match', {}).get('peer', {}).get('id', '')
        if ':topic:' in peer:
            parts = peer.split(':topic:')
            print(parts[0])
            break
        else:
            print(peer)
            break
" 2>/dev/null || echo "")

TOPIC_ID=$(python3 -c "
import json
d = json.load(open('$OPENCLAW_HOME/openclaw.json'))
for b in d.get('bindings', []):
    if b.get('agentId') == 'cto-factory':
        peer = b.get('match', {}).get('peer', {}).get('id', '')
        if ':topic:' in peer:
            print(peer.split(':topic:')[1])
            break
" 2>/dev/null || echo "")

[ -z "$CHAT_ID" ] && exit 0

# Format elapsed time
MINS=$((ELAPSED / 60))

# Send Telegram update
MSG="⏳ Build: $AGENT | Step: $STEP | Done: $DONE steps | ${MINS}m elapsed | $PY_COUNT py, $TEST_COUNT tests"

# Load env for openclaw CLI
if [ -f "$OPENCLAW_HOME/.env" ]; then
  set -a; . "$OPENCLAW_HOME/.env"; set +a
fi
export OPENCLAW_STATE_DIR="$OPENCLAW_HOME"
export OPENCLAW_CONFIG_PATH="$OPENCLAW_HOME/openclaw.json"

if [ -n "$TOPIC_ID" ]; then
  openclaw message send --channel telegram --target "$CHAT_ID:topic:$TOPIC_ID" -m "$MSG" --json >/dev/null 2>&1 || true
else
  openclaw message send --channel telegram --target "$CHAT_ID" -m "$MSG" --json >/dev/null 2>&1 || true
fi
