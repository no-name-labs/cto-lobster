# CTO Factory — Fix Plan v2

## F1: launch_build.py notify target bug
**Priority: Critical | Effort: 1 min**

Line 363: `notify(args.chat_id, args.topic_id, ...)` sends to agent topic (1655) instead of CTO topic (1269). Change to `notify(notify_chat, notify_topic, ...)`.

Becomes irrelevant after F2 but fix anyway as safety net.

File: `scripts/launch_build.py`

---

## F2: Remove ALL notify from launch_build.py
**Priority: High | Effort: 10 min**

launch_build.py = launch + progress file. No Telegram messages.

Notify sources after fix:
- **Lobster steps** — stage changes (T01 done, T02 started...)
- **build_monitor.sh cron** — heartbeat every 5 min
- **Lobster callback_cto** — final report via CTO agent

Remove: all `notify()` calls, `notify()` function, subprocess import for openclaw message send.

File: `scripts/launch_build.py`

---

## F3: Everything = T*.txt (unified numbering)
**Priority: Medium | Effort: 30 min**

Remove RESEARCH.txt, SMOKE.txt, VERIFY.txt as separate formats. Everything numbered:

```
T01.txt  — Research (sonnet)
T02.txt  — Scaffold/Architecture (opus)
T03.txt  — Core logic (sonnet)
T04.txt  — Processing (sonnet)
T05.txt  — Delivery (sonnet)
T06.txt  — Integration (opus)
T07.txt  — Smoke test (sonnet)
T08.txt  — Verification (opus)
```

CTO writes T01-T08 (or fewer). Lobster = one loop:
```bash
for f in $(ls "$PROMPTS_DIR"/T*.txt | sort); do
  code_agent_exec --prompt-file "$f" --timeout 900 || true
  # notify after each
done
```

Gate in launch_build.py: `ls T*.txt | wc -l >= 3`.

Models by number: T02/T06/T08 = opus, rest = sonnet. Or CTO specifies MODEL: in first line of prompt.

Files: `create-agent.lobster`, `launch_build.py`, `PROMPTS.md`, `SOUL.md`, `TOOLS.md`

---

## F4: Lobster notify auto-resolve CTO topic
**Priority: High | Effort: 15 min**

Each notify step resolves CTO binding from openclaw.json directly. No dependency on env vars.

```bash
CTO_TARGET=$(python3 -c "
import json; d=json.load(open('$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json'))
for b in d.get('bindings',[]):
    if b.get('agentId')=='cto-factory':
        print(b['match']['peer']['id']); break
")
openclaw message send --channel telegram --target "$CTO_TARGET" -m "..." || true
```

Remove `notify_chat_id`/`notify_topic_id` from lobster args completely.

Files: `create-agent.lobster`, `edit-agent.lobster`, `install-community-agent.lobster`, `launch_build.py`

---

## F5: Research on Sonnet
**Priority: High | Effort: 1 min**

T01 (research) = sonnet instead of opus. Fact gathering doesn't need opus. 2 min instead of 7.

Models after fix:
```
T01 Research     — sonnet
T02 Architecture — opus
T03-T05 Code     — sonnet
T06 Integration  — opus
T07 Smoke        — sonnet
T08 Verify       — opus
```

File: `create-agent.lobster`

---

## F6: Gateway restart doesn't kill pipeline/CTO
**Priority: High | Effort: 15 min**

Problem: macOS launchctl bootout + bootstrap is unreliable. Gateway dies → pipeline dies → CTO dies.

Fix: soft restart with fallback:
1. Try restart
2. If probe fails after 3 retries → do NOT block pipeline
3. Mark "gateway_restart: soft_fail" in progress
4. Continue to smoke (smoke will fail if gateway dead, that's OK)
5. callback_cto step already tries to start gateway before sending

Alternative: remove gateway restart from pipeline entirely. Register agent, notify user "restart gateway to activate". Smoke runs after manual restart.

Files: `create-agent.lobster`, `edit-agent.lobster`

---

## F7: Fallback when gateway dies mid-pipeline
**Priority: Medium | Effort: 10 min**

When gateway dies, CTO session is interrupted. No recovery.

Fix: build_monitor.sh checks gateway status. If dead + build was running:
1. Write status to `.cto-brain/runtime/build_status.txt`
2. Try `openclaw gateway install` to restart
3. On next CTO session boot: read build_status.txt, report to user

File: `scripts/build_monitor.sh`

---

## F8: Approval flow cleanup
**Priority: Medium | Effort: 5 min**

CTO uses lobster tool directly for resume (violates SOUL.md but works). Options:

A) Allow it — add `lobster resume` to SOUL.md allowed actions
B) CTO calls `exec` with lobster CLI instead of lobster tool
C) Remove approval gate — pipeline runs to end, CTO does post-verification

Recommendation: A — it works, just make it official.

File: `SOUL.md`

---

## F9: Inline buttons for sign-off and approval
**Priority: High | Effort: 15 min**

User presses button instead of typing YES.

Sign-off message with buttons:
```
📋 Requirements Sign-off: reddit-pain-finder
[spec table...]

[[✅ YES — Build it]] [[✏️ REVISE]] [[🛑 STOP]]
```

Approval gate message with buttons:
```
🔒 Approval: reddit-pain-finder
16 py files, 119 tests pass

[[✅ APPROVE]] [[❌ REJECT]]
```

CTO sends via: `openclaw message send --buttons '[[{"text":"✅ YES","callback_data":"signoff:yes:agent-id"},...]]'`

On callback: CTO receives `callback_data` → acts accordingly.

Files: `PROMPTS.md`, `SOUL.md`

---

## Execution Order

| # | Fix | Dependencies | Effort | Priority |
|---|-----|-------------|--------|----------|
| F1 | notify target bug | — | 1 min | Critical |
| F2 | Remove notify from launch_build | — | 10 min | High |
| F4 | Lobster notify auto-resolve | — | 15 min | High |
| F5 | Research on sonnet | — | 1 min | High |
| F6 | Gateway restart soft-fail | — | 15 min | High |
| F9 | Buttons for sign-off/approval | — | 15 min | High |
| F3 | Everything = T*.txt | F2, F4 | 30 min | Medium |
| F7 | Gateway death fallback | F2 | 10 min | Medium |
| F8 | Approval flow cleanup | — | 5 min | Medium |

F1+F2+F4+F5 — quick wins, do first.
F6+F9 — important UX, do second.
F3 — biggest refactor, after quick wins stabilize.
F7+F8 — polish, last.
