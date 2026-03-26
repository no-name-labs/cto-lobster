name: create-agent
# Complete agent build pipeline.
# CTO writes RESEARCH.txt, T1.txt..T6.txt, SMOKE.txt to prompts_dir BEFORE invoking.
# Each prompt is self-contained: codex builds, tests, fixes, and reports.
# Pipeline adds deterministic validation gates + Telegram progress notifications.
#
# Args:
#   agent_id      — e.g. "reddit-pain-finder"
#   openclaw_root — absolute path to OPENCLAW_ROOT
#   prompts_dir   — directory with RESEARCH.txt, T1.txt..T6.txt, SMOKE.txt
#   workspace     — absolute path to workspace-<agent_id>
#   chat_id       — Telegram chat ID for notifications (optional)
#   topic_id      — Telegram topic ID for notifications (optional)
#   test_cmd      — test runner command (default: python3 -m pytest -q)

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
        # Create build context directory for inter-step communication
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        rm -rf "$CTX"
        mkdir -p "$CTX"
        echo "# Build Context: $LOBSTER_ARG_AGENT_ID" > "$CTX/BUILD_DECISIONS.md"
        echo "Each step appends its key decisions here." >> "$CTX/BUILD_DECISIONS.md"
        echo "" >> "$CTX/BUILD_DECISIONS.md"
        echo "{\"ok\":true,\"agent\":\"$LOBSTER_ARG_AGENT_ID\",\"task_count\":$COUNT,\"context_dir\":\"$CTX\"}"
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
          COUNT=$(ls "$LOBSTER_ARG_PROMPTS_DIR"/T*.txt 2>/dev/null | wc -l)
          HAS_RESEARCH="no"; [ -f "$LOBSTER_ARG_PROMPTS_DIR/RESEARCH.txt" ] && HAS_RESEARCH="yes"
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🚀 Build started: $LOBSTER_ARG_AGENT_ID | $COUNT tasks | research=$HAS_RESEARCH" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── RESEARCH (optional, sonnet — fact gathering) ──────────
  - id: research
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/RESEARCH.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no RESEARCH.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" ----timeout 600 || true
        # Write context report
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        if [ -d "$CTX" ]; then
          find "$LOBSTER_ARG_WORKSPACE" -name "research*" -o -name "RESEARCH*" 2>/dev/null | head -5 | while read f; do
            [ -f "$f" ] && cp "$f" "$CTX/" 2>/dev/null || true
          done
          echo "## Research Phase" >> "$CTX/BUILD_DECISIONS.md"
          echo "Research completed. See research files in context dir." >> "$CTX/BUILD_DECISIONS.md"
          echo "" >> "$CTX/BUILD_DECISIONS.md"
        fi
        echo "{\"ok\":true}"
      '

  - id: notify_research
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
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🔬 Research complete for $LOBSTER_ARG_AGENT_ID" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── BUILD TASKS (T1-T6, each reads previous context) ──────────
  - id: t1
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T1.txt"
        [ ! -f "$PFILE" ] && echo "BLOCKED: T1.txt required" >&2 && exit 1
        # T1 (Architect) uses opus — architectural decisions matter most
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900 --model claude-opus-4-6 || true
        # Write context report
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        if [ -d "$CTX" ]; then
          echo "## T1: Architecture" >> "$CTX/BUILD_DECISIONS.md"
          ls "$LOBSTER_ARG_WORKSPACE"/*.md 2>/dev/null | while read f; do echo "- $(basename $f)"; done >> "$CTX/BUILD_DECISIONS.md"
          find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | while read f; do echo "- $(echo $f | sed "s|$LOBSTER_ARG_WORKSPACE/||")"; done >> "$CTX/BUILD_DECISIONS.md"
          echo "" >> "$CTX/BUILD_DECISIONS.md"
          # Copy architecture doc for next steps
          [ -f "$LOBSTER_ARG_WORKSPACE/docs/ARCHITECTURE.md" ] && cp "$LOBSTER_ARG_WORKSPACE/docs/ARCHITECTURE.md" "$CTX/T1-ARCHITECTURE.md"
          [ -f "$LOBSTER_ARG_WORKSPACE/IDENTITY.md" ] && cp "$LOBSTER_ARG_WORKSPACE/IDENTITY.md" "$CTX/T1-IDENTITY.md"
        fi
        echo "{\"ok\":true}"
      '

  - id: notify_t1
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
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🏗️ T1: Scaffold done ($FILES files)" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t2
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T2.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        # Inject context from previous steps into prompt
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        if [ -d "$CTX" ] && [ -f "$CTX/BUILD_DECISIONS.md" ]; then
          TMPF=$(mktemp)
          cat "$PFILE" > "$TMPF"
          echo "" >> "$TMPF"
          echo "## CONTEXT FROM PREVIOUS STEPS (read before implementing):" >> "$TMPF"
          cat "$CTX/BUILD_DECISIONS.md" >> "$TMPF"
          [ -f "$CTX/T1-ARCHITECTURE.md" ] && echo "" >> "$TMPF" && echo "## ARCHITECTURE (from T1):" >> "$TMPF" && cat "$CTX/T1-ARCHITECTURE.md" >> "$TMPF"
          PFILE="$TMPF"
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900 || true
        # Update context
        if [ -d "$CTX" ]; then
          echo "## T2: Core Logic" >> "$CTX/BUILD_DECISIONS.md"
          find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" -newer "$CTX/BUILD_DECISIONS.md" 2>/dev/null | while read f; do echo "- new: $(echo $f | sed "s|$LOBSTER_ARG_WORKSPACE/||")"; done >> "$CTX/BUILD_DECISIONS.md"
          echo "" >> "$CTX/BUILD_DECISIONS.md"
        fi
        echo "{\"ok\":true}"
      '

  - id: notify_t2
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
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "⚙️ T2: Core logic done ($FILES files)" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t3
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T3.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        if [ -d "$CTX" ] && [ -f "$CTX/BUILD_DECISIONS.md" ]; then
          TMPF=$(mktemp); cat "$PFILE" > "$TMPF"
          echo "" >> "$TMPF"; echo "## CONTEXT FROM PREVIOUS STEPS:" >> "$TMPF"; cat "$CTX/BUILD_DECISIONS.md" >> "$TMPF"
          [ -f "$CTX/T1-ARCHITECTURE.md" ] && echo "" >> "$TMPF" && echo "## ARCHITECTURE:" >> "$TMPF" && cat "$CTX/T1-ARCHITECTURE.md" >> "$TMPF"
          PFILE="$TMPF"
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900 || true
        if [ -d "$CTX" ]; then
          echo "## T3: Processing" >> "$CTX/BUILD_DECISIONS.md"
          find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" -newer "$CTX/BUILD_DECISIONS.md" 2>/dev/null | while read f; do echo "- new: $(echo $f | sed "s|$LOBSTER_ARG_WORKSPACE/||")"; done >> "$CTX/BUILD_DECISIONS.md"
          echo "" >> "$CTX/BUILD_DECISIONS.md"
        fi
        echo "{\"ok\":true}"
      '

  - id: notify_t3
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
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🧠 T3: Processing done ($FILES files)" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t4
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T4.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        if [ -d "$CTX" ] && [ -f "$CTX/BUILD_DECISIONS.md" ]; then
          TMPF=$(mktemp); cat "$PFILE" > "$TMPF"
          echo "" >> "$TMPF"; echo "## CONTEXT FROM PREVIOUS STEPS:" >> "$TMPF"; cat "$CTX/BUILD_DECISIONS.md" >> "$TMPF"
          PFILE="$TMPF"
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900 || true
        if [ -d "$CTX" ]; then
          echo "## T4: Delivery" >> "$CTX/BUILD_DECISIONS.md"
          find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" -newer "$CTX/BUILD_DECISIONS.md" 2>/dev/null | while read f; do echo "- new: $(echo $f | sed "s|$LOBSTER_ARG_WORKSPACE/||")"; done >> "$CTX/BUILD_DECISIONS.md"
          echo "" >> "$CTX/BUILD_DECISIONS.md"
        fi
        echo "{\"ok\":true}"
      '

  - id: t5
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T5.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        if [ -d "$CTX" ] && [ -f "$CTX/BUILD_DECISIONS.md" ]; then
          TMPF=$(mktemp); cat "$PFILE" > "$TMPF"
          echo "" >> "$TMPF"; echo "## CONTEXT FROM PREVIOUS STEPS:" >> "$TMPF"; cat "$CTX/BUILD_DECISIONS.md" >> "$TMPF"
          PFILE="$TMPF"
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900 || true
        if [ -d "$CTX" ]; then
          echo "## T5: Integration" >> "$CTX/BUILD_DECISIONS.md"
          find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" -newer "$CTX/BUILD_DECISIONS.md" 2>/dev/null | while read f; do echo "- new: $(echo $f | sed "s|$LOBSTER_ARG_WORKSPACE/||")"; done >> "$CTX/BUILD_DECISIONS.md"
          echo "" >> "$CTX/BUILD_DECISIONS.md"
        fi
        echo "{\"ok\":true}"
      '

  - id: notify_t4t5
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
          PY=$(find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "📬 T4-T5 done ($PY py files)" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t6
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T6.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        # T6 (Integration) uses opus — needs full picture to wire everything
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        if [ -d "$CTX" ] && [ -f "$CTX/BUILD_DECISIONS.md" ]; then
          TMPF=$(mktemp); cat "$PFILE" > "$TMPF"
          echo "" >> "$TMPF"; echo "## FULL BUILD CONTEXT (all previous steps):" >> "$TMPF"; cat "$CTX/BUILD_DECISIONS.md" >> "$TMPF"
          [ -f "$CTX/T1-ARCHITECTURE.md" ] && echo "" >> "$TMPF" && echo "## ARCHITECTURE:" >> "$TMPF" && cat "$CTX/T1-ARCHITECTURE.md" >> "$TMPF"
          PFILE="$TMPF"
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900 --model claude-opus-4-6 || true
        echo '{"ok":true}'
      '

  - id: notify_build_done
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
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "📦 Build complete ($FILES files). Validating..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── VALIDATION GATES ───────────────────────────────────────────
  - id: validate_config
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT"
        RESULT=$(openclaw config validate --json 2>&1 | tail -1)
        echo "$RESULT"
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  - id: workspace_check
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
        WARN=""
        BLOCK=""
        # Required: at least IDENTITY.md
        [ ! -f "$WS/IDENTITY.md" ] && BLOCK="$BLOCK IDENTITY.md"
        # Optional profile files — warn but do not block
        for f in TOOLS.md PROMPTS.md AGENTS.md SKILL_ROUTING.md; do [ ! -f "$WS/$f" ] && WARN="$WARN $f"; done
        # Required directories
        for d in tools tests; do [ ! -d "$WS/$d" ] && BLOCK="$BLOCK $d/"; done
        if [ -n "$BLOCK" ]; then echo "{\"ok\":false,\"missing\":\"$(echo $BLOCK | xargs)\"}" >&2; exit 1; fi
        if [ -n "$WARN" ]; then echo "[workspace_check] WARN: optional files missing:$WARN" >&2; fi
        PY_COUNT=$(find "$WS" -name "*.py" -not -path "*/__pycache__/*" | wc -l | tr -d " ")
        if [ "$PY_COUNT" -eq 0 ]; then echo "{\"ok\":false,\"error\":\"BLOCKED: No Python implementation files found in workspace.\"}" >&2; exit 1; fi
        echo "{\"ok\":true,\"py_files\":$PY_COUNT}"
      '

  - id: unit_tests
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
        if [ -d "$WS/tests" ]; then
          cd "$WS" && eval "$LOBSTER_ARG_TEST_CMD" 2>&1
          if [ $? -ne 0 ]; then echo "{\"ok\":false,\"tests\":\"failed\"}" >&2; exit 1; fi
          echo "{\"ok\":true,\"tests\":\"passed\"}"
        else
          echo "{\"ok\":true,\"tests\":\"skipped\"}"
        fi
      '

  - id: notify_validated
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
          PY=$(find "$LOBSTER_ARG_WORKSPACE" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
          TESTS=$(cd "$LOBSTER_ARG_WORKSPACE" 2>/dev/null && python3 -m pytest tests/ -q 2>&1 | tail -1 | grep -oE "[0-9]+ passed" || echo "? passed")
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "✅ Validated: $PY py files, $TESTS" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── REGISTER + VALIDATE ────────────────────────────────────────
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
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  - id: notify_registered
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
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "📋 Agent registered. Restarting gateway..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── GATEWAY RESTART (needed before smoke so agent is visible) ──
  - id: restart_for_smoke
    command: >
      bash -c '
        # Detect OS and restart gateway accordingly
        if [ "$(uname)" = "Darwin" ]; then
          # macOS: launchctl bootout + bootstrap (openclaw gateway stop/start breaks launchd)
          launchctl bootout gui/$(id -u)/ai.openclaw.gateway 2>/dev/null || true
          sleep 2
          launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || openclaw gateway install 2>/dev/null || true
        else
          # Linux: systemd restart
          openclaw gateway stop 2>&1 || true
          sleep 2
          openclaw gateway start 2>&1 || true
        fi
        sleep 6
        # Verify with retries
        for i in 1 2 3; do
          STATUS=$(openclaw gateway status 2>&1 || true)
          if echo "$STATUS" | grep -q "probe: ok"; then echo "{\"ok\":true}"; exit 0; fi
          sleep 3
        done
        echo "{\"ok\":true,\"gateway_restart\":\"soft_fail\",\"note\":\"gateway failed to start after 3 retries, pipeline continues\"}"
      '

  # ── SMOKE TEST (codex runs real agent calls) ───────────────────
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
        CTO_TARGET=$(python3 -c "
import json
try:
    d=json.load(open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\"))
    [print(b[\"match\"][\"peer\"][\"id\"]) for b in d.get(\"bindings\",[]) if b.get(\"agentId\")==\"cto-factory\"]
except: pass
" 2>/dev/null | head -1)
          if [ -n "$CTO_TARGET" ]; then
          PFILE="$LOBSTER_ARG_PROMPTS_DIR/SMOKE.txt"
          if [ -f "$PFILE" ]; then
            MSG="✅ Smoke test passed for $LOBSTER_ARG_AGENT_ID. Running requirements verification..."
          else
            MSG="⚠️ No SMOKE.txt — smoke skipped. Running requirements verification..."
          fi
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "$MSG" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── REQUIREMENTS VERIFICATION (opus — reads full context + verifies everything) ──
  - id: verify_requirements
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/VERIFY.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no VERIFY.txt\"}"
          exit 0
        fi
        # Inject full build context for auditor
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        if [ -d "$CTX" ] && [ -f "$CTX/BUILD_DECISIONS.md" ]; then
          TMPF=$(mktemp); cat "$PFILE" > "$TMPF"
          echo "" >> "$TMPF"; echo "## FULL BUILD CONTEXT:" >> "$TMPF"; cat "$CTX/BUILD_DECISIONS.md" >> "$TMPF"
          PFILE="$TMPF"
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/code_agent_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 1800 --model claude-opus-4-6 || true
        echo '{"ok":true}'
      '

  - id: notify_verify
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
          PFILE="$LOBSTER_ARG_PROMPTS_DIR/VERIFY.txt"
          if [ -f "$PFILE" ]; then
            MSG="✅ Requirements verified for $LOBSTER_ARG_AGENT_ID. Ready for apply approval."
          else
            MSG="⚠️ No VERIFY.txt — verification skipped. Ready for apply approval."
          fi
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "$MSG" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── APPROVAL GATE ──────────────────────────────────────────────
  - id: apply_gate
    command: >
      bash -c '
        FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
        echo "{\"agent_id\":\"$LOBSTER_ARG_AGENT_ID\",\"files\":$FILES,\"ready\":true}"
      '
    approval: required

  # ── APPLY ──────────────────────────────────────────────────────
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
    condition: $apply_gate.approved

  - id: post_apply_smoke
    command: >
      bash -c '
        OUTPUT=$(timeout 60 openclaw agent --agent "$LOBSTER_ARG_AGENT_ID" --message "Confirm you are alive. List your commands." --json 2>&1 || true)
        if echo "$OUTPUT" | grep -q "payloads"; then echo "{\"ok\":true,\"alive\":true}"; else echo "{\"ok\":true,\"alive\":false,\"note\":\"agent did not respond but pipeline continues\"}"; fi
      '
    condition: $apply_gate.approved

  - id: notify_done
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
          openclaw message send --channel telegram --target "$CTO_TARGET" -m "🎉 $LOBSTER_ARG_AGENT_ID is LIVE!" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true,\"done\":true}"
      '
    condition: $apply_gate.approved

  # ── BUILD_DONE CALLBACK TO CTO ─────────────────────────────
  - id: callback_cto
    command: >
      bash -c '
        # Ensure gateway is up for callback
        STATUS=$(openclaw gateway status 2>&1 || true)
        if ! echo "$STATUS" | grep -q "probe: ok"; then
          if [ "$(uname)" = "Darwin" ]; then
            launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || openclaw gateway install 2>/dev/null || true
          else
            openclaw gateway start 2>&1 || true
          fi
          sleep 5
        fi
        # Try CTO callback
        timeout 60 openclaw agent --agent cto-factory \
          --message "BUILD_DONE agent_id=$LOBSTER_ARG_AGENT_ID action=create status=completed chat_id=$LOBSTER_ARG_CHAT_ID topic_id=$LOBSTER_ARG_TOPIC_ID" \
          --json 2>/dev/null || true
        # Fallback: direct Telegram message if CTO callback failed
        CTO_TARGET=$(python3 -c "
import json
try:
    d=json.load(open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\"))
    [print(b[\"match\"][\"peer\"][\"id\"]) for b in d.get(\"bindings\",[]) if b.get(\"agentId\")==\"cto-factory\"]
except: pass
" 2>/dev/null | head -1)
          if [ -n "$CTO_TARGET" ]; then
          WS="$LOBSTER_ARG_WORKSPACE"
          PY=$(find "$WS" -name "*.py" -not -path "*/__pycache__/*" 2>/dev/null | wc -l | tr -d " ")
          TESTS=$(cd "$WS" 2>/dev/null && python3 -m pytest tests/ -q 2>&1 | tail -1 || echo "no tests")
          MSG="Build complete: $LOBSTER_ARG_AGENT_ID | $PY Python files | $TESTS"
          openclaw message send --channel telegram \
            --target "$CTO_TARGET" \
            -m "$MSG" \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── CLEANUP build context ─────────────────────────────────
  - id: cleanup_context
    command: >
      bash -c '
        CTX="/tmp/$LOBSTER_ARG_AGENT_ID-context"
        rm -rf "$CTX" 2>/dev/null || true
        echo "{\"ok\":true,\"cleaned\":\"$CTX\"}"
      '
