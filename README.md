# CTO Factory Agent (Lobster-First)

CTO Factory is an OpenClaw agent that builds other OpenClaw agents. It handles intake, prompt engineering, and pipeline management — all code work is delegated to code agents (Claude Code or Codex) inside lobster pipelines.

## Architecture

```
User → CTO (intake, prompts) → launch_build.py → lobster pipeline → code agent (codex/claude)
                                                       ↓
                                          research → build → test → register → smoke → verify → done
```

CTO does NOT write code. It writes task prompts with specific roles (Architect, Developer, QA Engineer, Auditor) and launches a deterministic pipeline that handles everything.

## Install

### Prerequisites

- OpenClaw installed and running (`openclaw gateway status` → `probe: ok`)
- Lobster CLI (`npm install -g @clawdbot/lobster`)
- Code agent: `codex` CLI or `claude` CLI in PATH

### Deploy

```bash
git clone https://github.com/no-name-labs/cto-lobster.git
cd cto-lobster
./scripts/deploy.sh
```

The deploy script:
1. Copies `workspace-factory/` to `~/.openclaw/workspace-factory/`
2. Registers `cto-factory` agent in `openclaw.json`
3. Restarts the gateway

### Options

```bash
# Custom OpenClaw home
OPENCLAW_HOME=/path/to/.openclaw ./scripts/deploy.sh

# Set model (default: anthropic/claude-opus-4-6)
CTO_MODEL=anthropic/claude-sonnet-4-6 ./scripts/deploy.sh

# Bind to Telegram group + topic
BIND_GROUP_ID="-100XXXXXXXXXX" BIND_TOPIC_ID="1234" ./scripts/deploy.sh
```

## Usage

After deploy, talk to CTO via Telegram or console:

```bash
openclaw agent --agent cto-factory --message "Build me an agent that monitors HN for trending AI posts"
```

CTO will:
1. Ask 2-3 clarifying questions
2. Present a requirements sign-off
3. On YES: write prompt files + launch the build pipeline
4. Report progress via Telegram
5. Deliver a working agent

## Pipelines

| Pipeline | File | Purpose |
|----------|------|---------|
| Create agent | `lobster/create-agent.lobster` | Full build from scratch |
| Edit agent | `lobster/edit-agent.lobster` | Modify existing agent |
| Diagnostic | `lobster/system-diagnostic.lobster` | Read-only health check |

## Files

```
workspace-factory/
├── SOUL.md              # Core rules (what CTO can/cannot do)
├── PROMPTS.md           # Prompt templates, intake flow, BUILD_DONE callback
├── IDENTITY.md          # Who CTO is
├── AGENTS.md            # State machine, workspace contracts
├── TOOLS.md             # Allowed tools (launch_build.py only)
├── SKILL_ROUTING.md     # Request → action routing
├── lobster/             # Pipeline definitions
├── scripts/
│   ├── launch_build.py          # Single entry point (self-daemonizing)
│   ├── code_agent_exec.py       # Codex/Claude wrapper with retry
│   └── lobster_register_agent.py # Agent registration + binding
├── skills/              # Skill definitions for intake
└── docs/                # Reference docs
```
