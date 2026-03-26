#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_CONFIG="${OPENCLAW_HOME}/openclaw.json"

log_info "Removing CTO Factory agent"

# Remove from config
python3 - "${OPENCLAW_CONFIG}" << 'PYEOF'
import json, sys
config_path = sys.argv[1]
with open(config_path) as f:
    d = json.load(f)
d["agents"]["list"] = [a for a in d.get("agents",{}).get("list",[]) if a.get("id") != "cto-factory"]
d["bindings"] = [b for b in d.get("bindings",[]) if b.get("agentId") != "cto-factory"]
with open(config_path, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print("[OK] cto-factory removed from config")
PYEOF

# Remove build monitor cron
if crontab -l 2>/dev/null | grep -q "build_monitor.sh"; then
  crontab -l 2>/dev/null | grep -v "build_monitor.sh" | crontab -
  log_info "Build monitor cron removed"
fi

# Restart gateway
log_info "Restarting gateway..."
if [ "$(uname)" = "Darwin" ]; then
  launchctl bootout "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
  sleep 2
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true
else
  openclaw gateway stop 2>&1 || true
  sleep 2
  openclaw gateway start 2>&1 || true
fi

log_info "CTO Factory removed. Workspace preserved at ${OPENCLAW_HOME}/workspace-factory/"
log_info "To fully remove: rm -rf ${OPENCLAW_HOME}/workspace-factory/"
