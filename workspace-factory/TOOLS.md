# TOOLS

## Pipeline launcher (THE way to build/edit/install agents)

```bash
python3 "$OPENCLAW_ROOT/workspace-factory/scripts/launch_build.py" \
  --action create \
  --agent-id <id> \
  --prompts-dir /tmp/<id>-build \
  --chat-id <telegram_chat_id> \
  --topic-id <telegram_topic_id>
```

Actions: `create`, `edit`, `install`, `diagnostic`

## OpenClaw Operations (scripts/ops/)

Safe, standalone scripts for managing OpenClaw. Each returns JSON. CTO can call read-only ops directly via `exec`. Mutating ops go through code agent or edit pipeline.

### Read-only (CTO calls directly via exec)

| Script | What it does |
|--------|-------------|
| `ops/gateway_status.py` | Check gateway health |
| `ops/config_validate.py` | Validate openclaw.json |
| `ops/agent_list.py` | List all agents + bindings |
| `ops/cron_list.py` | List cron jobs (filter by --agent) |
| `ops/sessions_list.py` | List agent sessions (--agent, --active N) |

**IMPORTANT:** Always use absolute path: `python3 /Users/.../workspace-factory/scripts/ops/...` — `$OPENCLAW_ROOT` does NOT resolve in exec.

### Mutating (CTO calls via exec with user confirmation)

| Script | What it does |
|--------|-------------|
| `ops/cron_create.py` | Create cron job (--agent, --schedule, --tz) |
| `ops/cron_delete.py` | Delete cron job (--id) |
| `ops/cron_toggle.py` | Enable/disable cron (--id, --enable/--disable) |
| `ops/gateway_restart.py` | Restart gateway (macOS/Linux aware, retries) |
| `ops/agent_bind.py` | Bind agent to Telegram topic (--agent, --chat-id, --topic-id) |
| `ops/agent_unbind.py` | Remove Telegram binding (--agent) |
| `ops/agent_delete.py` | Remove agent from config (--agent, --delete-workspace) |
| `ops/agent_set_model.py` | Change agent model (--agent, --model) |
| `ops/env_set.py` | Set env var in .env (--key, --value) |

Every mutating script: validates input → backs up → executes → verifies result → returns JSON.

## Allowed tools

- `read` — read any file for context
- `write` — ONLY to `/tmp/<agent>-build/` (prompt files) and `.cto-brain/` (memory)
- `exec` — run `launch_build.py`, ops scripts, read-only checks, memory writes
- `message` — send Telegram updates to user
- `sessions_list`, `session_status` — monitor agent sessions
- `web_search`, `web_fetch` — research during intake

## FORBIDDEN

- `codex exec`, `claude --print`, `code_agent_exec.py` — direct code agent calls
- `lobster run` directly — use `launch_build.py`
- Raw `openclaw cron/gateway/config` commands — use ops/ scripts instead
- Writing to agent workspaces — pipeline does this
- Any tool call that produces code or config changes outside the pipeline
