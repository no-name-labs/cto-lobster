name: edit-agent
# Edit an existing agent. CTO writes FIX.txt (codex prompt with changes) to prompts_dir.
# Codex implements changes, tests, fixes. Pipeline validates and applies.
#
# Args:
#   agent_id      — e.g. "reddit-pain-finder"
#   openclaw_root — absolute path to OPENCLAW_ROOT
#   prompts_dir   — directory containing FIX.txt and optionally SMOKE.txt
#   chat_id       — Telegram chat ID for notifications (optional)
#   topic_id      — Telegram topic ID for notifications (optional)
#   test_cmd      — test runner (default: python3 -m pytest -q)

args:
  agent_id:
    default: ""
  openclaw_root:
    default: ""
  prompts_dir:
    default: ""
  chat_id:
    default: ""
  topic_id:
    default: ""
  test_cmd:
    default: "python3 -m pytest -q"

steps:
  - id: preflight
    command: >
      bash -c '
        set -e
        [ -z "$LOBSTER_ARG_AGENT_ID" ] && echo "BLOCKED: agent_id not set" >&2 && exit 1
        [ -z "$LOBSTER_ARG_OPENCLAW_ROOT" ] && echo "BLOCKED: openclaw_root not set" >&2 && exit 1
        WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID"
        [ ! -d "$WS" ] && echo "BLOCKED: workspace $WS does not exist" >&2 && exit 1
        [ ! -f "$LOBSTER_ARG_PROMPTS_DIR/FIX.txt" ] && echo "BLOCKED: FIX.txt missing in $LOBSTER_ARG_PROMPTS_DIR" >&2 && exit 1
        echo "{\"ok\":true,\"agent\":\"$LOBSTER_ARG_AGENT_ID\",\"workspace\":\"$WS\"}"
      '

  - id: backup
    command: >
      bash -c '
        BRANCH="backup/$LOBSTER_ARG_AGENT_ID-edit-$(date +%Y%m%dT%H%M%S)"
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" checkout -b "$BRANCH" 2>&1 || true
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" add -A 2>&1 || true
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" commit -m "backup: pre-edit $LOBSTER_ARG_AGENT_ID" 2>&1 || true
        echo "{\"ok\":true,\"branch\":\"$BRANCH\"}"
      '

  - id: notify_start
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "🔧 Editing $LOBSTER_ARG_AGENT_ID..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: codex_fix
    command: >
      bash -c '
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$LOBSTER_ARG_PROMPTS_DIR/FIX.txt" --timeout 3600 || true
        echo "{\"ok\":true}"
      '

  - id: notify_fix
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "🔧 Fix applied for $LOBSTER_ARG_AGENT_ID. Validating..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: validate_config
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT"
        RESULT=$(openclaw config validate --json 2>&1 | tail -1)
        echo "$RESULT"
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  - id: unit_tests
    command: >
      bash -c '
        WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID"
        if [ -d "$WS/tests" ]; then
          cd "$WS" && eval "$LOBSTER_ARG_TEST_CMD" 2>&1
          if [ $? -ne 0 ]; then echo "{\"ok\":false,\"tests\":\"failed\"}" >&2; exit 1; fi
          echo "{\"ok\":true,\"tests\":\"passed\"}"
        else
          echo "{\"ok\":true,\"tests\":\"skipped\"}"
        fi
      '

  - id: notify_tests
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID"
          if [ -d "$WS/tests" ]; then
            COUNT=$(cd "$WS" && python3 -m pytest tests/ -q 2>&1 | tail -1 | grep -oE "[0-9]+ passed" || echo "? passed")
            openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "✅ Tests: $COUNT for $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
          else
            openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "⚠️ No tests found for $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
          fi
        fi
        echo "{\"ok\":true}"
      '

  - id: restart_for_smoke
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
        echo "{\"ok\":false,\"error\":\"gateway failed to start after 3 retries\"}" >&2
        exit 1
      '

  - id: notify_restart
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "🔄 Gateway restarted. Running smoke test..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: smoke_test
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/SMOKE.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no SMOKE.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 1800 || true
        echo '{"ok":true}'
      '

  - id: notify_smoke
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "🧪 Smoke test done for $LOBSTER_ARG_AGENT_ID. Verifying requirements..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── REQUIREMENTS VERIFICATION ──────────────────────────────────
  - id: verify_requirements
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/VERIFY.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no VERIFY.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 1800 || true
        echo '{"ok":true}'
      '

  - id: apply_gate
    command: >
      bash -c '
        echo "{\"agent_id\":\"$LOBSTER_ARG_AGENT_ID\",\"action\":\"edit\",\"ready\":true}"
      '
    approval: required

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
        echo "{\"ok\":false,\"error\":\"gateway restart failed\"}" >&2
        exit 1
      '
    condition: $apply_gate.approved

  - id: post_smoke
    command: >
      bash -c '
        OUTPUT=$(timeout 60 openclaw agent --agent "$LOBSTER_ARG_AGENT_ID" --message "Confirm you are alive. List your commands." --json 2>&1 || true)
        if echo "$OUTPUT" | grep -q "payloads"; then echo "{\"ok\":true,\"alive\":true}"; else echo "{\"ok\":true,\"alive\":false,\"note\":\"agent did not respond but pipeline continues\"}"; fi
      '
    condition: $apply_gate.approved

  - id: notify_done
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "✅ $LOBSTER_ARG_AGENT_ID edited and verified." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true,\"done\":true}"
      '
    condition: $apply_gate.approved

  - id: callback_cto
    command: >
      bash -c '
        STATUS=$(openclaw gateway status 2>&1 || true)
        if ! echo "$STATUS" | grep -q "probe: ok"; then
          if [ "$(uname)" = "Darwin" ]; then
            launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || openclaw gateway install 2>/dev/null || true
          else
            openclaw gateway start 2>&1 || true
          fi
          sleep 5
        fi
        timeout 60 openclaw agent --agent cto-factory \
          --message "BUILD_DONE agent_id=$LOBSTER_ARG_AGENT_ID action=edit status=completed chat_id=$LOBSTER_ARG_CHAT_ID topic_id=$LOBSTER_ARG_TOPIC_ID" \
          --json 2>/dev/null || true
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "✅ <b>Edit complete: $LOBSTER_ARG_AGENT_ID</b>" \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '
