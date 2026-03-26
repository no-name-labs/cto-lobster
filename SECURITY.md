# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| main    | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public issue**
2. Email: security@noname-labs.com
3. Include: description, reproduction steps, impact assessment

We will respond within 48 hours and work with you on a fix before public disclosure.

## Security Considerations

### Secrets

- Bot tokens, API keys, and OAuth tokens are stored in `~/.openclaw/.env` (chmod 600)
- Secrets are never committed to git (`.gitignore` covers all secret files)
- The install script prompts for secrets interactively and stores them locally only
- Code agents receive secrets via environment variables, never as command-line arguments

### Code Execution

- CTO Factory delegates all code execution to sandboxed code agents (Claude Code / Codex)
- Claude Code runs with `--dangerously-skip-permissions` — this is by design for autonomous builds
- Codex runs with `--sandbox danger-full-access` on isolated servers
- The lobster pipeline is deterministic and auditable

### Network

- OpenClaw gateway binds to loopback (127.0.0.1) by default
- Telegram communication goes through the official Bot API
- No inbound ports are opened
