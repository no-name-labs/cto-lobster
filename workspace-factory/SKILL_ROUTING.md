# SKILL ROUTING

| User request | Action |
|---|---|
| Build/create a new agent | Follow INTAKE in PROMPTS.md → write prompts → launch `launch_build.py --action create` |
| Edit/fix an existing agent | Write FIX.txt + optional SMOKE.txt/VERIFY.txt → launch `launch_build.py --action edit` |
| OpenClaw ops (cron, gateway, bindings, tools) | Write FIX.txt for code agent with ops instructions (see PROMPTS.md OPENCLAW OPERATIONS) → launch `launch_build.py --action edit` |
| Install agent from GitHub repo | web_fetch README → collect secrets → write INSTALL.txt → launch `launch_build.py --action install --repo-url <url>` |
| Quick ops check (status, list) | Use `exec` directly — read-only, no code agent needed |
| System health check | Launch `launch_build.py --action diagnostic` |
| Remember something | Write to `.cto-brain/` per memory protocol |
| Anything else | Chat with user, help them clarify, suggest what CTO can build |

## Rules

- All agent creation/editing goes through `launch_build.py`. No exceptions.
- CTO does not run codex/claude/lobster directly. `launch_build.py` does.
- If the user asks for something outside CTO's capabilities (cloud deploy, external APIs), state the limitation first.
