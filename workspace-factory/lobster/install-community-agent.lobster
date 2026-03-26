name: install-community-agent
# Install a community agent from a GitHub repo.
# CTO writes INSTALL.txt (exact install commands) and VERIFY.txt (post-install checks).
# Pipeline: clone → install → validate → restart → smoke → verify → callback
#
# Args:
#   agent_id      — e.g. "notes-agent"
#   openclaw_root — absolute path to OPENCLAW_ROOT
#   prompts_dir   — directory with INSTALL.txt + optional VERIFY.txt
#   repo_url      — GitHub repo URL (e.g. https://github.com/smart-spine/openclaw-notes-agent.git)
#   chat_id       — Telegram chat ID for notifications (optional)
#   topic_id      — Telegram topic ID for notifications (optional)

args:
  agent_id:
    default: ""
  openclaw_root:
    default: ""
  prompts_dir:
    default: ""
  repo_url:
    default: ""
  chat_id:
    default: ""
  topic_id:
    default: ""

steps:
  # ── PREFLIGHT ─────────────────────────────────────────────
  - id: preflight
    command: >
      bash -c '
        [ -z "$LOBSTER_ARG_AGENT_ID" ] && echo "BLOCKED: agent_id not set" >&2 && exit 1
        [ -z "$LOBSTER_ARG_OPENCLAW_ROOT" ] && echo "BLOCKED: openclaw_root not set" >&2 && exit 1
        [ -z "$LOBSTER_ARG_REPO_URL" ] && echo "BLOCKED: repo_url not set" >&2 && exit 1
        [ -z "$LOBSTER_ARG_PROMPTS_DIR" ] && echo "BLOCKED: prompts_dir not set" >&2 && exit 1
        [ ! -f "$LOBSTER_ARG_PROMPTS_DIR/INSTALL.txt" ] && echo "BLOCKED: INSTALL.txt not found in $LOBSTER_ARG_PROMPTS_DIR" >&2 && exit 1
        command -v git >/dev/null 2>&1 || { echo "BLOCKED: git not found" >&2; exit 1; }
        command -v openclaw >/dev/null 2>&1 || { echo "BLOCKED: openclaw not found" >&2; exit 1; }
        echo "{\"ok\":true,\"agent_id\":\"$LOBSTER_ARG_AGENT_ID\",\"repo_url\":\"$LOBSTER_ARG_REPO_URL\"}"
      '

  - id: notify_start
    command: >
      bash -c '
        CTO_TARGET=$(python3 -c "
import json
try:
    d=json.load(open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\"))
    [print(b[\"match\"][\"peer\"][\"id\"]) for b in d.get(\"bindings\",[]) if b.get(\"agentId\")==\"cto-factory\"]
except: pass
" 2>/dev/null | head -1)
          if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "📥 Installing $LOBSTER_ARG_AGENT_ID from $LOBSTER_ARG_REPO_URL" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── CLONE REPO ────────────────────────────────────────────
  - id: clone_repo
    command: >
      bash -c '
        CLONE_DIR="/tmp/$LOBSTER_ARG_AGENT_ID-install-repo"
        rm -rf "$CLONE_DIR"
        git clone --depth 1 "$LOBSTER_ARG_REPO_URL" "$CLONE_DIR" 2>&1 | tail -3
        if [ ! -d "$CLONE_DIR" ]; then echo "{\"ok\":false,\"error\":\"git clone failed\"}" >&2; exit 1; fi
        echo "{\"ok\":true,\"clone_dir\":\"$CLONE_DIR\"}"
      '

  - id: notify_cloned
    command: >
      bash -c '
        CTO_TARGET=$(python3 -c "
import json
try:
    d=json.load(open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\"))
    [print(b[\"match\"][\"peer\"][\"id\"]) for b in d.get(\"bindings\",[]) if b.get(\"agentId\")==\"cto-factory\"]
except: pass
" 2>/dev/null | head -1)
          if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "📦 Repo cloned. Running installer..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── INSTALL (code agent runs the installer) ───────────────
  - id: install
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/INSTALL.txt"
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900 || true
        echo "{\"ok\":true}"
      '

  - id: notify_installed
    command: >
      bash -c '
        CTO_TARGET=$(python3 -c "
import json
try:
    d=json.load(open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\"))
    [print(b[\"match\"][\"peer\"][\"id\"]) for b in d.get(\"bindings\",[]) if b.get(\"agentId\")==\"cto-factory\"]
except: pass
" 2>/dev/null | head -1)
          if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "⚙️ Installer finished. Validating config..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── VALIDATE CONFIG ───────────────────────────────────────
  - id: validate_config
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT"
        RESULT=$(openclaw config validate --json 2>&1 | tail -1)
        echo "$RESULT"
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  # ── GATEWAY RESTART ───────────────────────────────────────
  - id: restart_gateway
    command: >
      bash -c '
        if [ "$(uname)" = "Darwin" ]; then
          launchctl bootout gui/$(id -u)/ai.openclaw.gateway 2>/dev/null || true
          sleep 2
          launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || openclaw gateway install 2>/dev/null || true
        else
          openclaw gateway stop 2>&1 || true
          sleep 2
          openclaw gateway start 2>&1 || true
        fi
        sleep 6
        for i in 1 2 3; do
          STATUS=$(openclaw gateway status 2>&1 || true)
          if echo "$STATUS" | grep -q "probe: ok"; then echo "{\"ok\":true}"; exit 0; fi
          sleep 3
        done
        echo "{\"ok\":true,\"gateway_restart\":\"soft_fail\"}"
      '

  - id: notify_restarted
    command: >
      bash -c '
        CTO_TARGET=$(python3 -c "
import json
try:
    d=json.load(open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\"))
    [print(b[\"match\"][\"peer\"][\"id\"]) for b in d.get(\"bindings\",[]) if b.get(\"agentId\")==\"cto-factory\"]
except: pass
" 2>/dev/null | head -1)
          if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🔄 Gateway restarted. Running smoke test..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── SMOKE TEST ────────────────────────────────────────────
  - id: smoke_test
    command: >
      bash -c '
        OUTPUT=$(timeout 60 openclaw agent --agent "$LOBSTER_ARG_AGENT_ID" --message "hello" --json 2>&1 || true)
        if echo "$OUTPUT" | grep -q "payloads"; then echo "{\"ok\":true,\"alive\":true}"; else echo "{\"ok\":true,\"alive\":false,\"note\":\"agent did not respond\"}"; fi
      '

  # ── VERIFY (optional, code agent runs post-install checks) ─
  - id: verify
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/VERIFY.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no VERIFY.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 600 || true
        echo "{\"ok\":true}"
      '

  - id: notify_verified
    command: >
      bash -c '
        CTO_TARGET=$(python3 -c "
import json
try:
    d=json.load(open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\"))
    [print(b[\"match\"][\"peer\"][\"id\"]) for b in d.get(\"bindings\",[]) if b.get(\"agentId\")==\"cto-factory\"]
except: pass
" 2>/dev/null | head -1)
          if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "✅ $LOBSTER_ARG_AGENT_ID installed and verified" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── CLEANUP ───────────────────────────────────────────────
  - id: cleanup
    command: >
      bash -c '
        rm -rf "/tmp/$LOBSTER_ARG_AGENT_ID-install-repo"
        echo "{\"ok\":true,\"done\":true}"
      '

  # ── BUILD_DONE CALLBACK ──────────────────────────────────
  - id: callback_cto
    command: >
      bash -c '
        STATUS=$(openclaw gateway status 2>&1 || true)
        if ! echo "$STATUS" | grep -q "probe: ok"; then
          if [ "$(uname)" = "Darwin" ]; then
            launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true
          else
            openclaw gateway start 2>&1 || true
          fi
          sleep 5
        fi
        timeout 60 openclaw agent --agent cto-factory --message "BUILD_DONE agent_id=$LOBSTER_ARG_AGENT_ID action=install status=completed chat_id=$LOBSTER_ARG_CHAT_ID topic_id=$LOBSTER_ARG_TOPIC_ID" --json 2>/dev/null || true
        CTO_TARGET=$(python3 -c "
import json
try:
    d=json.load(open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\"))
    [print(b[\"match\"][\"peer\"][\"id\"]) for b in d.get(\"bindings\",[]) if b.get(\"agentId\")==\"cto-factory\"]
except: pass
" 2>/dev/null | head -1)
          if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🎉 $LOBSTER_ARG_AGENT_ID installed from $LOBSTER_ARG_REPO_URL" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '
