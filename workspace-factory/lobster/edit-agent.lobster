name: edit-agent
# Edit an existing agent. CTO writes FIX.txt to prompts_dir.
# Code agent implements changes. Pipeline validates and applies.
#
# Args:
#   agent_id, openclaw_root, prompts_dir, chat_id, topic_id, test_cmd

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
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🔧 Editing $LOBSTER_ARG_AGENT_ID..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: notify_fixing
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "⏳ Applying fix to $LOBSTER_ARG_AGENT_ID..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: codex_fix
    command: >
      bash -c '
        TMPF=$(mktemp)
        IDDIR="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/identities"
        [ -f "$IDDIR/T03-developer.md" ] && cat "$IDDIR/T03-developer.md" >> "$TMPF" && echo "" >> "$TMPF"
        echo "---" >> "$TMPF"
        echo "## YOUR TASK (from CTO):" >> "$TMPF"
        cat "$LOBSTER_ARG_PROMPTS_DIR/FIX.txt" >> "$TMPF"
        WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID"
        SNAP_BEFORE=$(find "$WS" -type f -not -path "*/__pycache__/*" -not -path "*/sessions/*" 2>/dev/null | sort | md5sum 2>/dev/null || find "$WS" -type f -not -path "*/__pycache__/*" -not -path "*/sessions/*" 2>/dev/null | sort | md5 2>/dev/null || echo "none")
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$TMPF" --timeout 3600 || true
        sync 2>/dev/null || true
        sleep 2
        SNAP_AFTER=$(find "$WS" -type f -not -path "*/__pycache__/*" -not -path "*/sessions/*" 2>/dev/null | sort | md5sum 2>/dev/null || find "$WS" -type f -not -path "*/__pycache__/*" -not -path "*/sessions/*" 2>/dev/null | sort | md5 2>/dev/null || echo "none")
        if [ "$SNAP_BEFORE" = "$SNAP_AFTER" ]; then
          CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
          [ -n "$CTO_TARGET" ] && openclaw message send --channel telegram --target "$CTO_TARGET" -m "⚠️ Fix step completed but no files were changed in workspace. Code agent may not have applied the fix." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: notify_fix
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🔧 Fix applied for $LOBSTER_ARG_AGENT_ID. Validating..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: validate_config
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT"
        RESULT=$(openclaw config validate --json 2>&1 | tail -1)
        echo "$RESULT"
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || {
          CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
          [ -n "$CTO_TARGET" ] && openclaw message send --channel telegram --target "$CTO_TARGET" -m "❌ Pipeline failed: validate_config | Config invalid | Agent: $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
          exit 1
        }
      '

  - id: unit_tests
    command: >
      bash -c '
        WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID"
        if [ -d "$WS/tests" ]; then
          cd "$WS" && eval "$LOBSTER_ARG_TEST_CMD" 2>&1
          if [ $? -ne 0 ]; then echo "{\"ok\":false,\"tests\":\"failed\"}" >&2
            CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
            [ -n "$CTO_TARGET" ] && openclaw message send --channel telegram --target "$CTO_TARGET" -m "❌ Pipeline failed: unit_tests | Tests failed | Agent: $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
            exit 1; fi
          echo "{\"ok\":true,\"tests\":\"passed\"}"
        else
          echo "{\"ok\":true,\"tests\":\"skipped\"}"
        fi
      '

  - id: notify_tests
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID"
          if [ -d "$WS/tests" ]; then
            COUNT=$(cd "$WS" && python3 -m pytest tests/ -q 2>&1 | tail -1 | grep -oE "[0-9]+ passed" || echo "? passed")
            openclaw message send --channel telegram --target "$CTO_TARGET" -m "✅ Tests: $COUNT for $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
          fi
        fi
        echo "{\"ok\":true}"
      '

  - id: restart_for_smoke
    command: >
      bash -c '
        STATUS=$(openclaw gateway status 2>&1 || true)
        if echo "$STATUS" | grep -q "probe: ok"; then
          echo "{\"ok\":true,\"gateway_restart\":\"skipped\"}"
          exit 0
        fi
        openclaw gateway stop 2>&1 || true
        sleep 3
        openclaw gateway start 2>&1 || true
        sleep 6
        for i in 1 2 3 4 5; do
          STATUS=$(openclaw gateway status 2>&1 || true)
          if echo "$STATUS" | grep -q "probe: ok"; then echo "{\"ok\":true}"; exit 0; fi
          sleep 3
        done
        if [ "$(uname)" = "Darwin" ]; then
          launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true
          sleep 5
          STATUS=$(openclaw gateway status 2>&1 || true)
          if echo "$STATUS" | grep -q "probe: ok"; then echo "{\"ok\":true}"; exit 0; fi
        fi
        echo "{\"ok\":true,\"gateway_restart\":\"soft_fail\"}"
      '

  - id: notify_restart
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🔄 Gateway restarted. Running smoke..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: notify_smoking
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🧪 Running smoke test for $LOBSTER_ARG_AGENT_ID..." --json 2>/dev/null || true
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
        TMPF=$(mktemp)
        IDDIR="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/identities"
        [ -f "$IDDIR/T07-qa.md" ] && cat "$IDDIR/T07-qa.md" >> "$TMPF" && echo "" >> "$TMPF"
        echo "---" >> "$TMPF"
        echo "## YOUR TASK:" >> "$TMPF"
        cat "$PFILE" >> "$TMPF"
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$TMPF" --timeout 1800 || true
        echo "{\"ok\":true}"
      '

  - id: notify_verifying
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "📝 Verifying requirements for $LOBSTER_ARG_AGENT_ID..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: verify_requirements
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/VERIFY.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no VERIFY.txt\"}"
          exit 0
        fi
        TMPF=$(mktemp)
        IDDIR="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/identities"
        [ -f "$IDDIR/T08-auditor.md" ] && cat "$IDDIR/T08-auditor.md" >> "$TMPF" && echo "" >> "$TMPF"
        echo "---" >> "$TMPF"
        echo "## YOUR TASK:" >> "$TMPF"
        cat "$PFILE" >> "$TMPF"
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$TMPF" --timeout 1800 --model claude-opus-4-6 || true
        echo "{\"ok\":true}"
      '

  # ── DONE ────────────────────────────────────────────────────
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
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID"
          PY=$(find "$WS" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
          TESTS=$(cd "$WS" 2>/dev/null && python3 -m pytest tests/ -q 2>&1 | tail -1 || echo "no tests")
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🎉 $LOBSTER_ARG_AGENT_ID — EDIT COMPLETE | $PY py files | $TESTS" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '
