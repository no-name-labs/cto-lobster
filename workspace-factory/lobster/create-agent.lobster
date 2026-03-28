name: create-agent
# Agent build pipeline — unified T01-T09 numbering.
# CTO writes T01.txt through T09.txt (or fewer). Pipeline iterates in order.
#
# Standard numbering:
#   T01 = Research (sonnet)
#   T02 = Architecture/Scaffold (opus)
#   T03-T05 = Implementation (sonnet)
#   T06 = Integration (opus)
#   T07 = Smoke test (sonnet)
#   T08 = Verification (opus)
#   T09 = Extra (if needed)
#
# Args:
#   agent_id, openclaw_root, prompts_dir, workspace, chat_id, topic_id, test_cmd

args:
  agent_id:
    default: ""
  openclaw_root:
    default: ""
  prompts_dir:
    default: ""
  workspace:
    default: ""
  chat_id:
    default: ""
  topic_id:
    default: ""
  test_cmd:
    default: "python3 -m pytest -q"

steps:
  # ── PREFLIGHT ──────────────────────────────────────────────────
  - id: preflight
    command: >
      bash -c '
        set -e
        [ -z "$LOBSTER_ARG_AGENT_ID" ] && echo "BLOCKED: agent_id not set" >&2 && exit 1
        [ -z "$LOBSTER_ARG_OPENCLAW_ROOT" ] && echo "BLOCKED: openclaw_root not set" >&2 && exit 1
        [ -z "$LOBSTER_ARG_PROMPTS_DIR" ] && echo "BLOCKED: prompts_dir not set" >&2 && exit 1
        COUNT=$(ls "$LOBSTER_ARG_PROMPTS_DIR"/T*.txt 2>/dev/null | wc -l)
        [ "$COUNT" -eq 0 ] && echo "BLOCKED: no T*.txt prompt files in $LOBSTER_ARG_PROMPTS_DIR" >&2 && exit 1
        mkdir -p "$LOBSTER_ARG_WORKSPACE" 2>/dev/null || true
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        rm -rf "$CTX"
        mkdir -p "$CTX"
        echo "# Build Context: $LOBSTER_ARG_AGENT_ID" > "$CTX/BUILD_DECISIONS.md"
        echo "{\"ok\":true,\"agent\":\"$LOBSTER_ARG_AGENT_ID\",\"task_count\":$COUNT}"
      '

  - id: notify_start
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          COUNT=$(ls "$LOBSTER_ARG_PROMPTS_DIR"/T*.txt 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🚀 Build started: $LOBSTER_ARG_AGENT_ID | $COUNT steps" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── T-STEPS (iterate all T*.txt in sorted order) ──────────────
  # Each T-step: notify_start → code_agent → notify_done → update context

  - id: run_t_steps
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        STEP_NUM=0
        TOTAL=$(ls "$LOBSTER_ARG_PROMPTS_DIR"/T*.txt 2>/dev/null | wc -l | tr -d " ")
        for PFILE in $(ls "$LOBSTER_ARG_PROMPTS_DIR"/T*.txt 2>/dev/null | sort); do
          STEP_NUM=$((STEP_NUM + 1))
          FNAME=$(basename "$PFILE")
          PY_BEFORE=$(find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
          # ── Notify: starting ──
          if [ -n "$CTO_TARGET" ]; then
            openclaw message send --channel telegram --target "$CTO_TARGET" -m "⏳ [$STEP_NUM/$TOTAL] Starting $FNAME..." --json 2>/dev/null || true
          fi
          # ── Inject identity + build context ──
          TMPF=$(mktemp)
          IDDIR="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/identities"
          # Prepend identity file based on step number
          case "$FNAME" in
            T01*) [ -f "$IDDIR/T01-researcher.md" ] && cat "$IDDIR/T01-researcher.md" >> "$TMPF" && echo "" >> "$TMPF" ;;
            T02*) [ -f "$IDDIR/T02-architect.md" ] && cat "$IDDIR/T02-architect.md" >> "$TMPF" && echo "" >> "$TMPF" ;;
            T03*) [ -f "$IDDIR/T03-developer.md" ] && cat "$IDDIR/T03-developer.md" >> "$TMPF" && echo "" >> "$TMPF" ;;
            T04*) [ -f "$IDDIR/T04-developer-delivery.md" ] && cat "$IDDIR/T04-developer-delivery.md" >> "$TMPF" && echo "" >> "$TMPF" ;;
            T05*) [ -f "$IDDIR/T05-developer-scheduler.md" ] && cat "$IDDIR/T05-developer-scheduler.md" >> "$TMPF" && echo "" >> "$TMPF" ;;
            T06*) [ -f "$IDDIR/T06-integrator.md" ] && cat "$IDDIR/T06-integrator.md" >> "$TMPF" && echo "" >> "$TMPF" ;;
            T07*) [ -f "$IDDIR/T07-qa.md" ] && cat "$IDDIR/T07-qa.md" >> "$TMPF" && echo "" >> "$TMPF" ;;
            T08*) [ -f "$IDDIR/T08-auditor.md" ] && cat "$IDDIR/T08-auditor.md" >> "$TMPF" && echo "" >> "$TMPF" ;;
          esac
          # Append CTO task prompt
          echo "---" >> "$TMPF"
          echo "## YOUR TASK (from CTO):" >> "$TMPF"
          cat "$PFILE" >> "$TMPF"
          # Append build context
          if [ -d "$CTX" ] && [ -f "$CTX/BUILD_DECISIONS.md" ]; then
            echo "" >> "$TMPF"
            echo "## CONTEXT FROM PREVIOUS STEPS:" >> "$TMPF"
            cat "$CTX/BUILD_DECISIONS.md" >> "$TMPF"
            [ -f "$CTX/T02-ARCHITECTURE.md" ] && echo "" >> "$TMPF" && echo "## ARCHITECTURE:" >> "$TMPF" && cat "$CTX/T02-ARCHITECTURE.md" >> "$TMPF"
          fi
          EXEC_FILE="$TMPF"
          # ── Select model: T02/T06/T08 = opus, rest = sonnet ──
          MODEL_FLAG=""
          case "$FNAME" in
            T02*|T06*|T08*) MODEL_FLAG="--model claude-opus-4-6" ;;
          esac
          # ── Run code agent ──
          SNAPSHOT_BEFORE=$(find "$LOBSTER_ARG_WORKSPACE" -type f -not -path "*/__pycache__/*" -not -path "*/sessions/*" 2>/dev/null | wc -l | tr -d " ")
          python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$EXEC_FILE" --timeout 900 $MODEL_FLAG || true
          # ── Verify code agent actually did something ──
          SNAPSHOT_AFTER=$(find "$LOBSTER_ARG_WORKSPACE" -type f -not -path "*/__pycache__/*" -not -path "*/sessions/*" 2>/dev/null | wc -l | tr -d " ")
          if [ "$STEP_NUM" -gt 1 ] && [ "$SNAPSHOT_AFTER" -eq "$SNAPSHOT_BEFORE" ] && [ "$SNAPSHOT_AFTER" -eq 0 ]; then
            if [ -n "$CTO_TARGET" ]; then
              openclaw message send --channel telegram --target "$CTO_TARGET" -m "⚠️ [$STEP_NUM/$TOTAL] $FNAME: code agent produced no files. Continuing but workspace may be incomplete." --json 2>/dev/null || true
            fi
          fi
          # ── Update context ──
          if [ -d "$CTX" ]; then
            echo "## $FNAME" >> "$CTX/BUILD_DECISIONS.md"
            PY_AFTER=$(find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
            NEW=$((PY_AFTER - PY_BEFORE))
            echo "Files: $PY_AFTER total ($NEW new)" >> "$CTX/BUILD_DECISIONS.md"
            find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" -newer "$CTX/BUILD_DECISIONS.md" 2>/dev/null | while read f; do echo "- $(echo $f | sed "s|$LOBSTER_ARG_WORKSPACE/||")"; done >> "$CTX/BUILD_DECISIONS.md" 2>/dev/null
            echo "" >> "$CTX/BUILD_DECISIONS.md"
            # Copy architecture doc if T02 created it
            [ -f "$LOBSTER_ARG_WORKSPACE/docs/ARCHITECTURE.md" ] && cp "$LOBSTER_ARG_WORKSPACE/docs/ARCHITECTURE.md" "$CTX/T02-ARCHITECTURE.md" 2>/dev/null
          fi
          # ── Notify: done ──
          PY_NOW=$(find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
          TEST_COUNT=""
          if [ -d "$LOBSTER_ARG_WORKSPACE/tests" ]; then
            TEST_COUNT=$(cd "$LOBSTER_ARG_WORKSPACE" && python3 -m pytest tests/ -q 2>&1 | tail -1 | grep -oE "[0-9]+ passed" || echo "")
          fi
          if [ -n "$CTO_TARGET" ]; then
            MSG="✅ [$STEP_NUM/$TOTAL] $FNAME done | $PY_NOW py files"
            [ -n "$TEST_COUNT" ] && MSG="$MSG | $TEST_COUNT"
            openclaw message send --channel telegram --target "$CTO_TARGET" -m "$MSG" --json 2>/dev/null || true
          fi
        done
        echo "{\"ok\":true,\"steps_run\":$STEP_NUM}"
      '

  # ── MID-PIPELINE CTO REPORT ──────────────────────────────────
  - id: mid_pipeline_report
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        WS="$LOBSTER_ARG_WORKSPACE"
        PY=$(find "$WS" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
        TESTS=""
        [ -d "$WS/tests" ] && TESTS=$(cd "$WS" && python3 -m pytest tests/ -q 2>&1 | tail -1 | grep -oE "[0-9]+ passed" || echo "")
        CTO_PEER="$LOBSTER_ARG_CHAT_ID"
        [ -n "$LOBSTER_ARG_TOPIC_ID" ] && CTO_PEER="${CTO_PEER}:topic:${LOBSTER_ARG_TOPIC_ID}"
        [ -z "$CTO_PEER" ] && CTO_PEER="$CTO_TARGET"
        openclaw agent --agent cto-factory --message "MIDPOINT_REPORT agent_id=$LOBSTER_ARG_AGENT_ID py_files=$PY tests=$TESTS workspace=$WS. All code steps complete. Validation starting next. Give the user a brief progress update." --deliver --reply-channel telegram --reply-to "$CTO_PEER" --timeout 60 --json 2>/dev/null || true
        echo "{\"ok\":true}"
      '

  # ── VALIDATION ────────────────────────────────────────────────
  - id: notify_validating
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🔍 All code steps done. Running validation..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: workspace_check
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
        BLOCK=""
        [ ! -f "$WS/IDENTITY.md" ] && BLOCK="$BLOCK IDENTITY.md"
        for d in tools tests; do [ ! -d "$WS/$d" ] && BLOCK="$BLOCK $d/"; done
        if [ -n "$BLOCK" ]; then echo "{\"ok\":false,\"missing\":\"$(echo $BLOCK | xargs)\"}" >&2
          CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
          [ -n "$CTO_TARGET" ] && openclaw message send --channel telegram --target "$CTO_TARGET" -m "❌ Pipeline failed: workspace_check | Missing: $(echo $BLOCK | xargs) | Agent: $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
          exit 1; fi
        PY_COUNT=$(find "$WS" -name "*.py" -not -path "*/__pycache__/*" | wc -l | tr -d " ")
        if [ "$PY_COUNT" -eq 0 ]; then echo "{\"ok\":false,\"error\":\"BLOCKED: No Python files in workspace.\"}" >&2
          CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
          [ -n "$CTO_TARGET" ] && openclaw message send --channel telegram --target "$CTO_TARGET" -m "❌ Pipeline failed: workspace_check | No Python files created | Agent: $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
          exit 1; fi
        echo "{\"ok\":true,\"py_files\":$PY_COUNT}"
      '

  - id: unit_tests
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
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

  - id: notify_validated
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          PY=$(find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
          TESTS=$(cd "$LOBSTER_ARG_WORKSPACE" 2>/dev/null && python3 -m pytest tests/ -q 2>&1 | tail -1 | grep -oE "[0-9]+ passed" || echo "? passed")
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "✅ Build validated: $PY py files, $TESTS. Registering..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── REGISTER + RESTART ────────────────────────────────────────
  - id: register_agent
    command: >
      bash -c '
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/lobster_register_agent.py" "$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json" "$LOBSTER_ARG_AGENT_ID" "$LOBSTER_ARG_WORKSPACE" "$LOBSTER_ARG_CHAT_ID" "$LOBSTER_ARG_TOPIC_ID"
      '

  - id: validate_after_register
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

  - id: notify_registered
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "📋 Agent registered. Restarting gateway..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: restart_for_smoke
    command: >
      bash -c '
        # Always restart — gateway needs to reload config to see newly registered agent
        if [ "$(uname)" = "Darwin" ]; then
          launchctl bootout gui/$(id -u)/ai.openclaw.gateway 2>/dev/null || true
          sleep 3
          launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true
        else
          openclaw gateway stop 2>&1 || true
          sleep 3
          openclaw gateway start 2>&1 || true
        fi
        sleep 8
        for i in 1 2 3 4 5 6; do
          STATUS=$(openclaw gateway status 2>&1 || true)
          if echo "$STATUS" | grep -q "probe: ok"; then
            # Gateway is up — wait extra 10s for agent sessions to initialize
            sleep 10
            echo "{\"ok\":true}"
            exit 0
          fi
          sleep 5
        done
        # Last resort: try launchctl on macOS
        if [ "$(uname)" = "Darwin" ]; then
          launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true
          sleep 10
          STATUS=$(openclaw gateway status 2>&1 || true)
          if echo "$STATUS" | grep -q "probe: ok"; then echo "{\"ok\":true}"; exit 0; fi
        fi
        echo "{\"ok\":true,\"gateway_restart\":\"soft_fail\"}"
      '

  - id: notify_restarted
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        if [ -n "$CTO_TARGET" ]; then
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🔄 Gateway restarted. Running smoke test..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── SMOKE + VERIFY (T07/T08 already ran in the T-loop above) ──
  # These are just post-apply verification — agent should already be tested
  - id: post_apply_smoke
    command: >
      bash -c '
        CTO_TARGET=$(bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/resolve_cto_topic.sh" "$LOBSTER_ARG_OPENCLAW_ROOT")
        # Retry smoke up to 4 times with 45s pause — agent needs ~2 min to init after gateway restart
        for ATTEMPT in 1 2 3 4; do
          OUTPUT=$(openclaw agent --agent "$LOBSTER_ARG_AGENT_ID" --message "Confirm you are alive. List your commands." --json --timeout 60 2>&1 || true)
          if echo "$OUTPUT" | grep -q "payloads"; then
            [ -n "$CTO_TARGET" ] && openclaw message send --channel telegram --target "$CTO_TARGET" -m "🧪 Smoke PASS — $LOBSTER_ARG_AGENT_ID is alive (attempt $ATTEMPT)" --json 2>/dev/null || true
            echo "{\"ok\":true,\"alive\":true}"
            exit 0
          fi
          if [ "$ATTEMPT" -lt 4 ]; then
            [ -n "$CTO_TARGET" ] && openclaw message send --channel telegram --target "$CTO_TARGET" -m "⏳ Smoke attempt $ATTEMPT failed, retrying in 45s..." --json 2>/dev/null || true
            sleep 45
          fi
        done
        # All retries exhausted
        [ -n "$CTO_TARGET" ] && openclaw message send --channel telegram --target "$CTO_TARGET" -m "❌ Pipeline failed: smoke | Agent not responding after 4 attempts | Agent: $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
        # Ensure gateway is up before sending CTO callback
        for _w in 1 2 3; do
          STATUS=$(openclaw gateway status 2>&1 || true)
          echo "$STATUS" | grep -q "probe: ok" && break
          sleep 5
        done
        # Send PIPELINE_FAILED to CTO with --deliver to user topic
        CTO_PEER="$LOBSTER_ARG_CHAT_ID"
        [ -n "$LOBSTER_ARG_TOPIC_ID" ] && CTO_PEER="${CTO_PEER}:topic:${LOBSTER_ARG_TOPIC_ID}"
        [ -z "$CTO_PEER" ] && CTO_PEER="$CTO_TARGET"
        openclaw agent --agent cto-factory --message "PIPELINE_FAILED agent_id=$LOBSTER_ARG_AGENT_ID step=smoke error=agent_not_responding_after_4_attempts. Report this failure to the user and suggest next steps." --deliver --reply-channel telegram --reply-to "$CTO_PEER" --timeout 90 --json 2>/dev/null || true
        echo "{\"ok\":false,\"alive\":false}" >&2
        exit 1
      '

  # ── DONE → notify + CTO final report ────────────────────────
  - id: callback_cto
    command: >
      bash -c '
        # Wait for gateway to be healthy before sending callback
        for _gw in 1 2 3 4 5 6 7 8; do
          STATUS=$(openclaw gateway status 2>&1 || true)
          echo "$STATUS" | grep -q "probe: ok" && break
          sleep 5
        done
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
          WS="$LOBSTER_ARG_WORKSPACE"
          PY=$(find "$WS" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
          TESTS=$(cd "$WS" 2>/dev/null && python3 -m pytest tests/ -q 2>&1 | tail -1 || echo "no tests")
          ELAPSED=$(($(date +%s) - $(stat -c %Y "$WS/IDENTITY.md" 2>/dev/null || stat -f %m "$WS/IDENTITY.md" 2>/dev/null || date +%s)))
          ELAPSED_MIN=$((ELAPSED / 60))
          MSG="🎉 $LOBSTER_ARG_AGENT_ID — BUILD COMPLETE | ${ELAPSED_MIN}m | $PY py files | $TESTS | Telegram topic $LOBSTER_ARG_TOPIC_ID"
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "$MSG" --json 2>/dev/null || true
        fi
        # Send BUILD_DONE to CTO with --deliver so CTO writes a report to the topic
        CTO_PEER="$LOBSTER_ARG_CHAT_ID"
        [ -n "$LOBSTER_ARG_TOPIC_ID" ] && CTO_PEER="${CTO_PEER}:topic:${LOBSTER_ARG_TOPIC_ID}"
        [ -z "$CTO_PEER" ] && CTO_PEER="$CTO_TARGET"
        openclaw agent --agent cto-factory --message "BUILD_DONE agent_id=$LOBSTER_ARG_AGENT_ID action=create status=completed py_files=$PY tests=$TESTS elapsed=${ELAPSED_MIN}m topic=$LOBSTER_ARG_TOPIC_ID. Send a final build report to the user." --deliver --reply-channel telegram --reply-to "$CTO_PEER" --timeout 90 --json 2>/dev/null || true
        echo "{\"ok\":true}"
      '

  # ── CLEANUP ───────────────────────────────────────────────────
  - id: cleanup_context
    command: >
      bash -c '
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        rm -rf "$CTX" 2>/dev/null || true
        echo "{\"ok\":true}"
      '
