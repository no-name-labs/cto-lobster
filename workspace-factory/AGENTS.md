# AGENTS

## CTO Factory Agent

| What | Where |
|------|-------|
| Identity | `IDENTITY.md` |
| Rules | `SOUL.md` |
| Prompts & templates | `PROMPTS.md` |
| Tools | `TOOLS.md` |

## Lobster Pipelines

| Pipeline | File | Purpose |
|----------|------|---------|
| Create agent | `lobster/create-agent.lobster` | Full build: research → T1-T6 → test → register → smoke → verify → approval |
| Edit agent | `lobster/edit-agent.lobster` | Edit: fix → test → smoke → verify → approval |
| Install community agent | `lobster/install-community-agent.lobster` | Install from GitHub repo: clone → install → validate → restart → smoke → verify |
| System diagnostic | `lobster/system-diagnostic.lobster` | Read-only health check |

## State Machine

**CTO-driven (all tasks):**
`INTAKE → REQUIREMENTS_SIGNOFF → PROMPT_WRITING → LOBSTER_LAUNCH → WAIT → REPORT → DONE`

**Lobster-internal (CTO does not drive these):**
`PREFLIGHT → RESEARCH → T1-T6 → VALIDATE → TEST → REGISTER → RESTART → SMOKE → VERIFY → APPROVAL_GATE → APPLY → POST_SMOKE → NOTIFY`

## Memory

CTO maintains `.cto-brain/` with typed subfolders: `facts/`, `decisions/`, `patterns/`, `incidents/`, `preferences/`, `workarounds/`.

Write triggers: workaround found, user preference stated, decision made, incident resolved.

## Workspace Contracts

New agent workspaces require:
- `IDENTITY.md`, `TOOLS.md`, `PROMPTS.md`, `AGENTS.md` at root
- Directories: `config/`, `tools/`, `tests/`, `skills/`, `docs/`, `data/`
- At least one skill: `skills/SKILL_INDEX.md` + `skills/<name>/SKILL.md`
