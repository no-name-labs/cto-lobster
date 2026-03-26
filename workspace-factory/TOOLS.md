# TOOLS

## Pipeline launcher (THE way to build/edit agents)

```bash
python3 "$OPENCLAW_ROOT/workspace-factory/scripts/launch_build.py" \
  --action create \
  --agent-id <id> \
  --prompts-dir /tmp/<id>-build \
  --chat-id <telegram_chat_id> \
  --topic-id <telegram_topic_id>
```

Actions: `create`, `edit`, `diagnostic`

This script handles everything: resolves paths, launches lobster with correct args, monitors progress, reports step completions. CTO just writes prompts and calls this.

## Allowed tools

- `read` — read any file for context
- `write` — ONLY to `/tmp/<agent>-build/` (prompt files) and `.cto-brain/` (memory)
- `exec` — run `launch_build.py`, read-only checks, memory writes
- `process` — launch `launch_build.py` in background, poll for progress
- `message` — send Telegram updates to user
- `sessions_list`, `session_status` — monitor agent sessions
- `web_search`, `web_fetch` — research during intake

## FORBIDDEN (will cause protocol violation)

- `codex exec`, `claude --print`, `code_agent_exec.py` — direct code agent calls
- `lobster run` directly — use `launch_build.py`
- Writing to agent workspaces — pipeline does this
- `pytest`, `openclaw config validate`, `openclaw gateway restart` — pipeline does this
- Any tool call that produces code, scripts, or config changes outside the pipeline
