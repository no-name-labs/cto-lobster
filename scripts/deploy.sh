#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_CONFIG="${OPENCLAW_HOME}/openclaw.json"
CTO_MODEL="${CTO_MODEL:-anthropic/claude-opus-4-6}"
CTO_FALLBACK="${CTO_FALLBACK:-anthropic/claude-sonnet-4-6}"
BIND_GROUP_ID="${BIND_GROUP_ID:-}"
BIND_TOPIC_ID="${BIND_TOPIC_ID:-}"

# ── Preflight ──────────────────────────────────────────────

log_info "CTO Factory Deploy (lobster-first)"
log_info "OpenClaw home: ${OPENCLAW_HOME}"

if [ ! -f "${OPENCLAW_CONFIG}" ]; then
  log_error "openclaw.json not found at ${OPENCLAW_CONFIG}"
  log_error "Install OpenClaw first: https://docs.openclaw.ai"
  exit 1
fi

if ! command -v openclaw &>/dev/null; then
  log_error "'openclaw' CLI not found in PATH"
  exit 1
fi

if ! command -v lobster &>/dev/null; then
  log_warn "'lobster' CLI not found. Installing..."
  npm install -g @clawdbot/lobster || {
    log_error "Failed to install lobster. Run: npm install -g @clawdbot/lobster"
    exit 1
  }
fi

# ── Deploy workspace ──────────────────────────────────────

WORKSPACE_DEST="${OPENCLAW_HOME}/workspace-factory"
log_info "Deploying workspace-factory to ${WORKSPACE_DEST}"

if [ -d "${WORKSPACE_DEST}" ]; then
  BACKUP="${WORKSPACE_DEST}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
  log_info "Existing workspace found, backing up to ${BACKUP}"
  cp -r "${WORKSPACE_DEST}" "${BACKUP}"
fi

rsync -av --delete \
  --exclude='.cto-brain' \
  --exclude='__pycache__' \
  --exclude='.pytest_cache' \
  --exclude='node_modules' \
  --exclude='auth-profiles.json' \
  --exclude='sessions' \
  --exclude='.openclaw' \
  "${REPO_ROOT}/workspace-factory/" "${WORKSPACE_DEST}/"

chmod +x "${WORKSPACE_DEST}/scripts/"*.sh 2>/dev/null || true
chmod +x "${WORKSPACE_DEST}/scripts/"*.py 2>/dev/null || true

log_info "Workspace deployed ($(find "${WORKSPACE_DEST}" -type f | wc -l | tr -d ' ') files)"

# ── Register agent ─────────────────────────────────────────

log_info "Registering cto-factory agent (model: ${CTO_MODEL})"

python3 - "${OPENCLAW_CONFIG}" "${CTO_MODEL}" "${CTO_FALLBACK}" "${WORKSPACE_DEST}" "${BIND_GROUP_ID}" "${BIND_TOPIC_ID}" << 'PYEOF'
import json, sys

config_path, model, fallback, workspace, group_id, topic_id = sys.argv[1:7]

with open(config_path) as f:
    d = json.load(f)

agents = d.setdefault("agents", {}).setdefault("list", [])

# Update or create cto-factory
cto = None
for a in agents:
    if a.get("id") == "cto-factory":
        cto = a
        break
if cto is None:
    cto = {"id": "cto-factory", "default": True}
    agents.append(cto)

cto.update({
    "name": "CTO Factory",
    "workspace": workspace,
    "agentDir": workspace,
    "model": {
        "primary": model,
        "fallbacks": [fallback] if fallback and fallback != model else []
    },
    "identity": {"name": "CTO Factory Agent"},
    "tools": {"alsoAllow": ["lobster"], "deny": ["cron"]},
})

# Add lobster to plugins
plugins = d.setdefault("plugins", {})
allow = plugins.setdefault("allow", [])
if "lobster" not in allow:
    allow.append("lobster")
plugins.setdefault("entries", {})["lobster"] = {"enabled": True}

# Add binding if group_id provided
if group_id:
    bindings = d.setdefault("bindings", [])
    peer_id = f"{group_id}:topic:{topic_id}" if topic_id else group_id
    # Remove old bindings to same peer (prevents routing collision)
    bindings[:] = [b for b in bindings if b.get("match", {}).get("peer", {}).get("id") != peer_id or b.get("agentId") == "cto-factory"]
    exists = any(
        b.get("agentId") == "cto-factory"
        and b.get("match", {}).get("peer", {}).get("id") == peer_id
        for b in bindings
    )
    if not exists:
        bindings.append({
            "agentId": "cto-factory",
            "match": {
                "channel": "telegram",
                "accountId": "default",
                "peer": {"kind": "group", "id": peer_id}
            }
        })
        print(f"[BIND] cto-factory → {peer_id}")

with open(config_path, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)

print("[OK] cto-factory registered")
PYEOF

# ── Validate ───────────────────────────────────────────────

VALID=$(openclaw config validate --json 2>&1 | tail -1)
if echo "${VALID}" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('valid') else 1)" 2>/dev/null; then
  log_info "Config valid"
else
  log_error "Config invalid after registration:"
  echo "${VALID}"
  exit 1
fi

# ── Restart gateway ────────────────────────────────────────

log_info "Restarting gateway..."
if [ "$(uname)" = "Darwin" ]; then
  launchctl bootout "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
  sleep 2
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || openclaw gateway install 2>/dev/null || true
else
  openclaw gateway stop 2>&1 || true
  sleep 2
  openclaw gateway start 2>&1 || true
fi

sleep 5

STATUS=$(openclaw gateway status 2>&1 || true)
if echo "${STATUS}" | grep -q "probe: ok"; then
  log_info "Gateway: probe ok"
else
  log_warn "Gateway probe failed. You may need to start it manually."
fi

# ── Build monitor cron ─────────────────────────────────────

MONITOR_SCRIPT="${WORKSPACE_DEST}/scripts/build_monitor.sh"
if [ -f "${MONITOR_SCRIPT}" ]; then
  chmod +x "${MONITOR_SCRIPT}"
  CRON_LINE="*/5 * * * * OPENCLAW_HOME=${OPENCLAW_HOME} ${MONITOR_SCRIPT} >/dev/null 2>&1"
  if ! crontab -l 2>/dev/null | grep -q "build_monitor.sh"; then
    (crontab -l 2>/dev/null || true; echo "${CRON_LINE}") | crontab -
    log_info "Build monitor cron installed (every 5 min)"
  else
    log_info "Build monitor cron already installed"
  fi
fi

# ── Done ───────────────────────────────────────────────────

log_info "CTO Factory deployed successfully!"
log_info ""
log_info "Test: openclaw agent --agent cto-factory --message 'hello'"
if [ -n "${BIND_GROUP_ID}" ]; then
  log_info "Telegram: bound to group ${BIND_GROUP_ID} topic ${BIND_TOPIC_ID:-default}"
fi
