# CTO Factory Agent

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

An [OpenClaw](https://openclaw.ai) agent that builds other OpenClaw agents. You describe what you want in Telegram — CTO handles the rest: research, architecture, implementation, testing, registration, and deployment.

## How It Works

```
You (Telegram) → CTO (intake, prompts) → Lobster Pipeline → Code Agent (Claude/Codex)
                                               ↓
                                  🔬 Research → 🏗️ Build → 🧪 Test → 📋 Register → ✅ Verify → 🎉 Live
```

CTO is an **orchestrator** — it does not write code itself. It writes task prompts with specific roles (Architect, Developer, QA Engineer, Auditor) and launches a deterministic [Lobster](https://github.com/openclaw/lobster) pipeline that handles everything.

You get Telegram notifications at every stage so you always know what's happening.

## Quick Install

Make sure `curl` is available (most systems have it, fresh Ubuntu containers may not):

```bash
# Ubuntu/Debian — if curl is missing:
apt-get update && apt-get install -y curl

# Then install CTO:
curl -fsSL https://raw.githubusercontent.com/no-name-labs/cto-lobster/main/scripts/install.sh | bash
```

The installer handles everything:
1. System dependencies (Node.js 22, Python, git)
2. OpenClaw CLI + Lobster CLI + Claude Code CLI
3. Anthropic OAuth authentication
4. OpenClaw gateway configuration
5. Telegram bot setup
6. CTO Factory deployment

### Non-Interactive Install

```bash
TELEGRAM_BOT_TOKEN="your-token" \
TELEGRAM_GROUP_ID="-100XXXXXXXXXX" \
TELEGRAM_TOPIC_ID="1269" \
TELEGRAM_ALLOWED_USERS="your-telegram-user-id" \
NON_INTERACTIVE=true \
  curl -fsSL https://raw.githubusercontent.com/no-name-labs/cto-lobster/main/scripts/install.sh | bash
```

### Manual Install

```bash
git clone https://github.com/no-name-labs/cto-lobster.git
cd cto-lobster
./scripts/deploy.sh
```

## Prerequisites

- **Ubuntu 22.04+** or **macOS 13+**
- **Anthropic account** with Opus access (for Claude Code OAuth)
- **Telegram bot** created via [@BotFather](https://t.me/BotFather)
- **Telegram group** with a topic for CTO

## Usage

After installation, talk to CTO in your Telegram group:

```
You: I want an agent that monitors GitHub trending repos daily and sends me a digest

CTO: Got it. A few questions:
     1. Data source? A) GitHub API  B) Web scraping
     2. Digest format? A) Text  B) Text + file
     Pick your options.

You: B, A

CTO: Here's the requirements sign-off:
     [detailed spec table]
     Reply YES to build.

You: YES

CTO: 🚀 Build started: github-trending-scout
     🔬 Research complete
     🏗️ T1: Scaffold done (24 files)
     ⚙️ T2: Core logic done (35 files)
     🧠 T3: Processing done (42 files)
     📦 Build complete. Validating...
     ✅ Validated: 15 py files, 212 passed
     📋 Agent registered. Restarting gateway...
     🧪 Smoke test passed
     📝 Requirements verified
     🎉 github-trending-scout is LIVE!
```

Or via CLI:

```bash
openclaw agent --agent cto-factory --message "Build me a weather alert agent"
```

## What CTO Can Do

### Build Agents
- Create new agents from a simple description — full pipeline: research, architecture, implementation, testing, registration, deployment
- Edit existing agents — describe changes, CTO handles the rest
- Install community agents from GitHub repos (e.g. [Notes Agent](https://github.com/smart-spine/openclaw-notes-agent))
- Handles secrets collection (API keys, tokens) during intake
- Manages Telegram binding for each agent

### Manage OpenClaw (17 ops scripts)

**Read-only — ask CTO anytime:**
| What | Example |
|------|---------|
| Gateway health | "Is the gateway running?" |
| Config validation | "Is my config valid?" |
| List agents | "What agents do I have?" |
| List cron jobs | "Show me all scheduled jobs" |
| Agent sessions | "Show active sessions" |
| Gateway logs | "Show me recent gateway logs" |
| Config backups | "List my config backups" |

**Mutating — CTO asks for confirmation:**
| What | Example |
|------|---------|
| Create cron job | "Set up daily cron for my-agent at 9am UTC" |
| Delete cron job | "Remove that cron job" |
| Enable/disable cron | "Pause the daily scan" |
| Restart gateway | "Restart the gateway" |
| Bind agent to topic | "Move my-agent to topic 1655" |
| Unbind agent | "Remove Telegram binding for my-agent" |
| Delete agent | "Remove old-agent completely" |
| Change agent model | "Switch my-agent to Opus" |
| Set environment variable | "Add GITHUB_TOKEN to .env" |
| Toggle plugin | "Disable the telegram plugin" |
| Backup config | "Back up my config before changes" |
| Restore config | "Restore config from yesterday's backup" |

### Monitor Builds
- Real-time Telegram notifications at every pipeline step
- Progress tracking via `build_progress.json`
- Automatic failure detection and reporting
- Beautiful per-step reports from CTO

## Architecture

### Pipelines

| Pipeline | File | Purpose |
|----------|------|---------|
| Create | `lobster/create-agent.lobster` | Build new agent from scratch |
| Edit | `lobster/edit-agent.lobster` | Modify existing agent |
| Install | `lobster/install-community-agent.lobster` | Install agent from GitHub repo |
| Diagnostic | `lobster/system-diagnostic.lobster` | Read-only health check |

### Installing Community Agents

CTO can install agents published by the community (like [Notes Agent](https://github.com/smart-spine/openclaw-notes-agent)):

```
You: Install notes-agent from https://github.com/smart-spine/openclaw-notes-agent

CTO: I read the README. This agent needs:
     - Telegram bot token
     - Telegram group ID
     - Assignees list
     Ready to install?

You: YES

CTO: 📥 Installing notes-agent...
     📦 Repo cloned
     ⚙️ Installer finished
     🔄 Gateway restarted
     ✅ Verified
     🎉 notes-agent installed!
```

### File Structure

```
workspace-factory/
├── SOUL.md              # Core rules and constraints
├── PROMPTS.md           # Prompt templates, intake flow, BUILD_DONE callback
├── IDENTITY.md          # Agent identity
├── AGENTS.md            # State machine, workspace contracts
├── TOOLS.md             # Allowed tools (launch_build.py only)
├── SKILL_ROUTING.md     # Request → action routing
├── lobster/             # Pipeline definitions
├── scripts/
│   ├── launch_build.py          # Pipeline launcher (self-daemonizing)
│   ├── code_agent_exec.py       # Claude/Codex wrapper with retry
│   └── lobster_register_agent.py # Agent registration + Telegram binding
├── skills/              # Skill definitions
└── docs/                # Reference documentation
```

### Key Design Decisions

- **CTO never writes code** — it writes prompts that tell code agents what to build
- **Each pipeline step has a role** — Researcher, Architect, Developer, QA Engineer, Auditor
- **Pipeline is deterministic** — lobster handles sequencing, CTO handles creativity
- **Self-daemonizing launcher** — `launch_build.py` forks immediately, CTO stays responsive
- **Progress tracking** — `.cto-brain/runtime/build_progress.json` keeps CTO informed between turns
- **Telegram notifications** — unique emoji per stage, user always knows what's happening

## Configuration

### Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token from BotFather | Yes |
| `OPENCLAW_GATEWAY_TOKEN` | Gateway auth token (auto-generated) | Auto |
| `OPENCLAW_PORT` | Gateway port (default: 18789) | No |
| `OPENCLAW_CODE_AGENT_CLI` | Code agent: `claude` or `codex` (default: `claude`) | No |

### Model

CTO runs on `anthropic/claude-opus-4-6` with `claude-sonnet-4-6` as fallback. Code agents use `claude-sonnet-4-6` by default.

To change: edit `model.primary` in `openclaw.json` for the `cto-factory` agent.

## Uninstall

```bash
./scripts/undeploy.sh
```

This removes the agent from OpenClaw config. To fully remove:

```bash
rm -rf ~/.openclaw/workspace-factory
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Copyright 2026 [Noname Labs](https://github.com/no-name-labs).
