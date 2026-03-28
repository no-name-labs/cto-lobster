# AGENTS

## CTO Factory Agent

| What | Where |
|------|-------|
| Identity | `IDENTITY.md` |
| Rules | `SOUL.md` |
| Prompts & templates | `PROMPTS.md` |
| Tools | `TOOLS.md` |

## Critical: How CTO Launches Builds

**CTO does NOT run code.** CTO writes task prompts and calls `launch_build.py` via `exec`.

```
User says YES
  ↓
CTO writes T01.txt - T08.txt to /tmp/<agent>-build/    ← write tool calls
  ↓
CTO calls exec: python3 launch_build.py --action create ...   ← exec tool call (MANDATORY)
  ↓
launch_build.py spawns lobster pipeline in background
  ↓
Lobster runs T01→T08 with identity injection + notifications
  ↓
Pipeline: register → restart gateway → smoke → BUILD_DONE callback to CTO
  ↓
CTO receives BUILD_DONE → sends report to user
```

**If CTO skips the `exec` call, nothing happens.** Files sit in /tmp and no pipeline runs.

## Lobster Pipelines

| Pipeline | File | Purpose |
|----------|------|---------|
| Create agent | `lobster/create-agent.lobster` | Full build: T01-T08 → validate → register → restart → smoke → callback |
| Edit agent | `lobster/edit-agent.lobster` | Edit: FIX.txt → validate → test → restart → smoke → verify → callback |
| Install community | `lobster/install-community-agent.lobster` | Clone → install → validate → restart → smoke → verify → callback |
| Diagnostic | `lobster/system-diagnostic.lobster` | Read-only health check |

## T-Step Numbering (T01-T08)

| Step | Identity | Model | Role |
|------|----------|-------|------|
| T01 | T01-researcher.md | sonnet | Research APIs, data sources, feasibility |
| T02 | T02-architect.md | opus | Design architecture, create workspace scaffold |
| T03 | T03-developer.md | sonnet | Implement core module |
| T04 | T04-developer-delivery.md | sonnet | Implement message delivery/formatting |
| T05 | T05-developer-scheduler.md | sonnet | Implement scheduling/automation |
| T06 | T06-integrator.md | opus | Wire modules, E2E tests |
| T07 | T07-qa.md | sonnet | Smoke test via openclaw agent CLI |
| T08 | T08-auditor.md | opus | Verify ALL requirements, register cron |

**File naming: T01.txt through T08.txt (leading zero required).** T1.txt will be rejected by launch_build.py gate.

## Cron Registration

Cron jobs are created by the **T08 auditor** code agent (NOT by CTO directly). T08 identity has full `openclaw cron create` knowledge including `--announce --channel telegram --to` for delivery.

If cron is not created after build, check:
1. T08 prompt mentions cron requirement
2. T08 identity file has cron CLI docs
3. Code agent had permission to run `openclaw cron create`

## State Machine

**CTO-driven:**
`INTAKE → SIGNOFF → PROMPT_WRITING → EXEC_LAUNCH → WAIT → REPORT → DONE`

**Lobster-internal (CTO does not drive):**
`PREFLIGHT → T01-T08 (with identity injection) → VALIDATE → TEST → REGISTER → RESTART → SMOKE (4 retries) → CALLBACK_CTO`


## Progress Tracking

**Real-time progress**: Telegram notifications in CTO topic (⏳/✅ per step)
**Post-mortem**: .cto-brain/runtime/build_progress.json (status: running/completed/failed)

Note: build_progress.json shows high-level status only (not individual T-steps).
The Telegram topic is the authoritative real-time source during active builds.
## Runtime State

| File | Purpose |
|------|---------|
| `.cto-brain/runtime/build_progress.json` | Pipeline status (written by launch_build.py) |
| `.cto-brain/runtime/launch_build.log` | Debug log |
| `.cto-brain/runtime/build.lock` | Lockfile preventing duplicate launches |

## Workspace Contracts

New agent workspaces require:
- `IDENTITY.md`, `TOOLS.md`, `PROMPTS.md` at root
- Directories: `tools/`, `tests/`
- Optional: `config/`, `skills/`, `docs/`, `AGENTS.md`, `SOUL.md`
