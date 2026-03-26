---
name: factory-create-agent
description: Intake flow and requirements for creating a new agent via lobster pipeline.
---

## GOAL
Create a production-usable OpenClaw agent. CTO handles intake, code agent does all building.

## INTAKE

Required inputs before sign-off:
- Agent name and mission
- Target destination (Telegram group/topic)
- Data sources and APIs needed
- Schedule (cron) if applicable
- Model preference
- Interaction mode (commands/buttons)

If critical inputs missing: `BLOCKED: MISSING_CRITICAL_INPUTS`

## TASK DECOMPOSITION

Break implementation into 5-6 sub-tasks:
- T1: Scaffold + profile files + architecture
- T2: Core business logic module
- T3: Data processing / analysis
- T4: Delivery / output formatting
- T5: Integration + end-to-end wiring
- T6: (optional) Advanced features

Each becomes a separate prompt file with a specific code agent role.

## BUILD

After user says YES:

**Step 1** — Write prompt files to `/tmp/<agent_id>-build/`:
- `RESEARCH.txt`, `T1.txt`-`T5.txt`, `SMOKE.txt`, `VERIFY.txt`
- Each file gives the code agent a specific identity (see PROMPTS.md templates)

**Step 2** — Launch pipeline:
```bash
python3 "$OPENCLAW_ROOT/workspace-factory/scripts/launch_build.py" \
  --action create --agent-id <id> --prompts-dir /tmp/<id>-build
```

**Step 3** — Monitor and report progress to user.

Pipeline handles everything: research, build, test, register, gateway restart, smoke, verify, approval.

## EDITING

Same pattern with `--action edit`:
- Write `FIX.txt` (required) + optional `SMOKE.txt`, `VERIFY.txt`
- Launch: `launch_build.py --action edit --agent-id <id> --prompts-dir /tmp/<id>-edit`

## WORKSPACE STRUCTURE

New agent workspaces must have:
- `IDENTITY.md`, `TOOLS.md`, `PROMPTS.md`, `AGENTS.md` at root
- Directories: `config/`, `tools/`, `tests/`, `skills/`, `docs/`, `data/`
- At least one skill in `skills/`

## DONE

Pipeline reports success or failure. CTO relays to user with evidence.
