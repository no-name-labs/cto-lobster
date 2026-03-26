---
name: factory-intake
description: Parse user request into task intent, collect all required inputs, produce sign-off package.
---

## When to use
- Any agent creation request
- Any non-trivial agent edit
- Any install-from-repo request

## Required inputs for agent creation

Do NOT proceed to sign-off until all are resolved:

1. **Data source strategy** — how the agent gets its data (API, scraping, webhooks, etc.)
2. **Schedule/trigger policy** — on-command, cron, or event-driven
3. **Failure/retry policy** — what happens when something fails
4. **Interaction mode** — commands only, buttons, or both
5. **Model preference** — which LLM the agent uses (or none)
6. **Delivery target** — where output goes (Telegram topic, file, etc.)
7. **Secrets plan** — every API key/token needed, listed by env var name
8. **Telegram binding** — group ID + topic ID for the agent

## Interaction mode classifier

Automatically classify:
- `COMPLEX_INTERACTIVE=YES` if ANY of:
  - 2+ business modes/workflows
  - Configurable runtime controls exposed to users
  - Long-running actions needing cancel/status
  - More than 5 primary user actions
- If `COMPLEX_INTERACTIVE=YES`: buttons mandatory, `/menu` as entry point
- Otherwise: commands are fine

## Vague reply handling

If user gives vague answers ("just make it work", "figure it out"):
- List exactly which inputs are still missing
- Present 2-3 options per missing input
- Do NOT proceed — return `BLOCKED: MISSING_CRITICAL_INPUTS`

## Task decomposition (mandatory)

Before sign-off, break into T1-T6:
- Each task: independently testable, single concern
- Format: `T1: <what> | acceptance: <how to verify>`
- Show to user in sign-off — they catch scope issues before YES

## Sign-off package

Must include ALL of:
- Mission (1-2 sentences)
- Numbered requirements list
- Technical decisions table (with rationale)
- Output contract (exact format/fields)
- Implementation plan (T1-T6 with acceptance criteria)
- Telegram binding
- Secrets required
- Defaults/assumptions applied

Response options: YES / REVISE / STOP

## For routine edits

Skip full intake. Only ask about:
- What to change and why
- Any new secrets needed
- Telegram binding changes (if any)
