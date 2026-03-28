#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# CTO Factory Agent — One-Script Installer
#
# Installs everything from scratch:
#   1. System dependencies (Node.js, Python, git)
#   2. OpenClaw CLI + Lobster CLI + Claude Code CLI
#   3. OpenClaw config + gateway
#   4. Telegram bot setup + pairing
#   5. CTO Factory agent (lobster-first architecture)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/no-name-labs/cto-lobster/main/scripts/install.sh | bash
#
# Non-interactive:
#   TELEGRAM_BOT_TOKEN=xxx TELEGRAM_GROUP_ID=-100xxx TELEGRAM_TOPIC_ID=1269 \
#     curl -fsSL ... | bash
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ──────────────────────────────────────────────────

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
CTO_MODEL="anthropic/claude-opus-4-6"
CTO_FALLBACK="anthropic/claude-sonnet-4-6"
CTO_REPO="https://github.com/no-name-labs/cto-lobster.git"
CTO_BRANCH="${CTO_BRANCH:-main}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_GROUP_ID="${TELEGRAM_GROUP_ID:-}"
TELEGRAM_TOPIC_ID="${TELEGRAM_TOPIC_ID:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

# ── Helpers ─────────────────────────────────────────────────

ts() { date -u +"%H:%M:%S"; }
info()  { printf "[%s] ✅ %s\n" "$(ts)" "$*"; }
warn()  { printf "[%s] ⚠️  %s\n" "$(ts)" "$*" >&2; }
error() { printf "[%s] ❌ %s\n" "$(ts)" "$*" >&2; }
die()   { error "$*"; exit 1; }

prompt_value() {
  local var_name="$1" prompt_text="$2" optional="${3:-false}"
  local current="${!var_name:-}"
  [ -n "$current" ] && return 0
  if [ "$NON_INTERACTIVE" = "true" ]; then
    [ "$optional" = "true" ] && return 0
    die "Missing required: $var_name (NON_INTERACTIVE=true)"
  fi
  local entered=""
  if [ "$optional" = "true" ]; then
    read -r -p "$prompt_text (optional, press Enter to skip): " entered </dev/tty
  else
    while [ -z "$entered" ]; do
      read -r -p "$prompt_text: " entered </dev/tty
    done
  fi
  printf -v "$var_name" "%s" "$entered"
}

prompt_secret() {
  local var_name="$1" prompt_text="$2" optional="${3:-false}"
  local current="${!var_name:-}"
  [ -n "$current" ] && return 0
  if [ "$NON_INTERACTIVE" = "true" ]; then
    [ "$optional" = "true" ] && return 0
    die "Missing required: $var_name (NON_INTERACTIVE=true)"
  fi
  local entered=""
  while [ -z "$entered" ]; do
    read -r -s -p "$prompt_text: " entered </dev/tty; echo
  done
  printf -v "$var_name" "%s" "$entered"
}

wait_for_user() {
  if [ "$NON_INTERACTIVE" = "true" ]; then return 0; fi
  read -r -p "$1" </dev/tty
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

upsert_env() {
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"; chmod 600 "$file" 2>/dev/null || true
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file"
    rm -f "${file}.bak"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

detect_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "macos" ;;
    *)       die "Unsupported OS: $(uname -s)" ;;
  esac
}

# ── Stage 1: System Dependencies ────────────────────────────

install_deps() {
  local os="$1"
  info "Installing system dependencies..."

  if [ "$os" = "linux" ]; then
    if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
      info "Installing Node.js 22..."
      run_root bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
      run_root apt-get install -y -qq nodejs
    fi
    run_root apt-get install -y -qq git python3 curl jq rsync
  elif [ "$os" = "macos" ]; then
    if ! command -v node >/dev/null 2>&1; then
      if command -v brew >/dev/null 2>&1; then
        brew install node
      else
        die "Install Node.js: https://nodejs.org or 'brew install node'"
      fi
    fi
    for cmd in git python3 curl jq; do
      command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd. Install via brew."
    done
  fi

  info "Node $(node --version), Python $(python3 --version | awk '{print $2}')"
}

# ── Stage 2: OpenClaw + Lobster + Claude Code ───────────────

install_tools() {
  local os="$1"

  if ! command -v openclaw >/dev/null 2>&1; then
    info "Installing OpenClaw CLI..."
    if [ "$os" = "linux" ]; then
      run_root npm install -g openclaw@latest
    else
      npm install -g openclaw@latest
    fi
  else
    info "OpenClaw already installed: $(openclaw --version 2>&1 | head -1)"
  fi

  if ! command -v lobster >/dev/null 2>&1; then
    info "Installing Lobster CLI..."
    if [ "$os" = "linux" ]; then
      run_root npm install -g @clawdbot/lobster
    else
      npm install -g @clawdbot/lobster
    fi
  else
    info "Lobster already installed: $(lobster version 2>&1)"
  fi

  if ! command -v claude >/dev/null 2>&1; then
    info "Installing Claude Code CLI..."
    if [ "$os" = "linux" ]; then
      run_root npm install -g @anthropic-ai/claude-code
    else
      npm install -g @anthropic-ai/claude-code
    fi
  else
    info "Claude Code already installed: $(claude --version 2>&1 | head -1)"
  fi
}

# ── Stage 3: Anthropic OAuth ────────────────────────────────

extract_oauth_token_from_log() {
  local log_path="$1"
  [ -f "$log_path" ] || return 1
  local cleaned
  cleaned="$(tr -d '\r' <"$log_path" | sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g')"
  # Extract sk-ant-oat token (may wrap across lines)
  local token
  token="$(printf "%s\n" "$cleaned" | awk '
    BEGIN { collect=0; tok="" }
    {
      line=$0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (collect == 1) {
        if (line ~ /^[A-Za-z0-9._-]+$/) { tok = tok line; next }
        collect = 0
      }
      if (line ~ /^sk-ant-oat[A-Za-z0-9._-]*$/) { tok = line; collect = 1; next }
    }
    END { if (tok != "") print tok }
  ' | tail -n1 || true)"
  [ -n "$token" ] && printf "%s" "$token" && return 0
  return 1
}

apply_oauth_token() {
  local token="$1"
  local auth_store="$OPENCLAW_HOME/workspace-factory/auth-profiles.json"
  python3 - "$auth_store" "$token" << 'PYEOF'
import json, pathlib, sys, time
store_path = pathlib.Path(sys.argv[1])
token = sys.argv[2].strip()
store_path.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(store_path.read_text()) if store_path.exists() else {}
if not isinstance(data, dict): data = {}
data["version"] = 1
profiles = data.setdefault("profiles", {})
profiles["anthropic:oauth"] = {
    "type": "token", "provider": "anthropic", "token": token,
    "expires": int(time.time() * 1000) + 365 * 24 * 60 * 60 * 1000,
}
store_path.write_text(json.dumps(data, indent=2) + "\n")
PYEOF
}

setup_anthropic_auth() {
  info "Setting up Anthropic authentication..."

  # Check if already authenticated
  if claude auth status >/dev/null 2>&1; then
    info "Claude Code already authenticated."
    return 0
  fi

  if [ "$NON_INTERACTIVE" = "true" ]; then
    warn "Non-interactive mode: skipping OAuth. Run 'claude setup-token' manually."
    return 0
  fi

  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  Anthropic Authentication                                    ║"
  echo "║                                                               ║"
  echo "║  You need an Anthropic account with a Claude subscription.   ║"
  echo "║                                                               ║"
  echo "║  What will happen:                                           ║"
  echo "║  1. Claude CLI shows a URL                                   ║"
  echo "║  2. Open it in your browser (on any device)                  ║"
  echo "║  3. Sign in to Anthropic                                     ║"
  echo "║  4. Copy the token it gives you (starts with sk-ant-oat...) ║"
  echo "║  5. Paste the token back here                                ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo ""

  local setup_log
  setup_log="$(mktemp)"
  local captured_token=""

  if command -v script >/dev/null 2>&1; then
    # Use 'script' to capture output while keeping terminal interactive
    script -q -e -c "claude setup-token" "$setup_log" </dev/tty >/dev/tty 2>&1 || true
    captured_token="$(extract_oauth_token_from_log "$setup_log" || true)"
  else
    claude setup-token </dev/tty >/dev/tty 2>&1 || true
  fi
  rm -f "$setup_log"

  # If we captured the token, apply it to auth-profiles
  if [ -n "$captured_token" ]; then
    info "Token captured, saving to auth-profiles..."
    apply_oauth_token "$captured_token"
  fi

  # Verify
  if claude auth status >/dev/null 2>&1; then
    info "Anthropic authentication verified."
  else
    warn "Auth not verified. You can retry later: claude setup-token"
  fi
}

# ── Stage 4: OpenClaw Config + Gateway ──────────────────────

setup_openclaw() {
  local os="$1"
  info "Configuring OpenClaw..."

  mkdir -p "$OPENCLAW_HOME"

  # Generate gateway token if missing
  local gw_token=""
  if grep -q "OPENCLAW_GATEWAY_TOKEN=" "$OPENCLAW_HOME/.env" 2>/dev/null; then
    gw_token="$(grep 'OPENCLAW_GATEWAY_TOKEN=' "$OPENCLAW_HOME/.env" | head -1 | cut -d= -f2-)"
  fi
  if [ -z "$gw_token" ]; then
    gw_token="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
  fi

  upsert_env "$OPENCLAW_HOME/.env" "OPENCLAW_GATEWAY_TOKEN" "$gw_token"
  upsert_env "$OPENCLAW_HOME/.env" "OPENCLAW_PORT" "$OPENCLAW_PORT"
  upsert_env "$OPENCLAW_HOME/.env" "OPENCLAW_CODE_AGENT_CLI" "claude"

  # Create or update openclaw.json
  python3 - "$OPENCLAW_HOME/openclaw.json" "$OPENCLAW_HOME" "$OPENCLAW_PORT" "$gw_token" << 'PYEOF'
import json, pathlib, sys
config_path = pathlib.Path(sys.argv[1])
home = sys.argv[2]
port = int(sys.argv[3])
token = sys.argv[4]

d = json.loads(config_path.read_text()) if config_path.exists() else {}

d.setdefault("gateway", {}).update({"port": port, "mode": "local", "bind": "loopback"})
d["gateway"].setdefault("auth", {"mode": "token", "token": f"${{OPENCLAW_GATEWAY_TOKEN}}"})

auth = d.setdefault("auth", {})
profiles = auth.setdefault("profiles", {})
profiles.setdefault("anthropic:claude-cli", {"provider": "anthropic", "mode": "token"})

d.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {"primary": "anthropic/claude-sonnet-4-6"})
d["agents"].setdefault("list", [])
d.setdefault("bindings", [])
d.setdefault("plugins", {}).setdefault("allow", [])

config_path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYEOF

  # Start gateway
  info "Starting gateway..."
  if [ "$os" = "macos" ]; then
    openclaw gateway install 2>/dev/null || true
    sleep 3
  else
    # Try systemd first, fall back to foreground (Docker/containers)
    if openclaw gateway start 2>/dev/null; then
      sleep 3
    else
      info "systemd unavailable, starting gateway in foreground..."
      mkdir -p "$OPENCLAW_HOME/logs"
      (
        cd "$OPENCLAW_HOME"
        export OPENCLAW_STATE_DIR="$OPENCLAW_HOME"
        export OPENCLAW_CONFIG_PATH="$OPENCLAW_HOME/openclaw.json"
        if [ -f "$OPENCLAW_HOME/.env" ]; then set -a; . "$OPENCLAW_HOME/.env"; set +a; fi
        nohup openclaw gateway run --port "$OPENCLAW_PORT" > "$OPENCLAW_HOME/logs/gateway.log" 2>&1 &
        echo $! > "$OPENCLAW_HOME/.gateway.pid"
      )
      sleep 5
    fi
  fi

  # Verify
  local probe
  probe="$(openclaw gateway status 2>&1 || true)"
  if echo "$probe" | grep -q "probe: ok"; then
    info "Gateway running (port $OPENCLAW_PORT)"
  else
    warn "Gateway probe failed. Check logs: $OPENCLAW_HOME/logs/gateway.log"
  fi
}

# ── Stage 5: Telegram Setup ─────────────────────────────────

parse_telegram_topic_link() {
  local link="$1" token="$2"
  local parsed_json
  parsed_json="$(python3 - "$link" "$token" << 'PYEOF'
import json, re, sys
from urllib.parse import urlparse

raw = (sys.argv[1] or "").strip()
bot_token = (sys.argv[2] or "").strip()

if not raw:
    raise SystemExit("Telegram link is empty.")
if not re.match(r"^https?://", raw, flags=re.I):
    raw = "https://" + raw

parsed = urlparse(raw)
host = parsed.netloc.lower()
if host not in {"t.me", "www.t.me", "telegram.me", "www.telegram.me"}:
    raise SystemExit("Unsupported Telegram host.")

parts = [p for p in parsed.path.split("/") if p]
if len(parts) < 2:
    raise SystemExit("Invalid Telegram link format.")

group_id = ""
topic_id = ""

if parts[0] == "c":
    if len(parts) < 3:
        raise SystemExit("Invalid t.me/c link: missing topic ID.")
    topic_id = parts[2]
    if parts[1].isdigit():
        group_id = f"-100{parts[1]}"
    else:
        raise SystemExit("Use numeric t.me/c/<number>/<topic> link.")
else:
    username = parts[0]
    topic_id = parts[1]
    if not bot_token:
        raise SystemExit("Username-based link requires bot token. Use t.me/c/<number>/<topic> instead.")
    from urllib.request import Request, urlopen
    url = f"https://api.telegram.org/bot{bot_token}/getChat?chat_id=@{username}"
    with urlopen(Request(url, headers={"Accept": "application/json"}), timeout=15) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if not payload.get("ok"):
        raise SystemExit(payload.get("description", "getChat failed"))
    group_id = str(payload["result"]["id"])

if not topic_id.isdigit():
    raise SystemExit("Topic ID must be numeric.")

print(json.dumps({"group_id": group_id, "topic_id": topic_id}))
PYEOF
)" || return 1
  TELEGRAM_GROUP_ID="$(printf "%s" "$parsed_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['group_id'])")"
  TELEGRAM_TOPIC_ID="$(printf "%s" "$parsed_json" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['topic_id'])")"
}

setup_telegram() {
  info "Setting up Telegram..."

  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  Telegram Setup                                              ║"
  echo "║                                                               ║"
  echo "║  CTO lives in a Telegram group topic. You need:             ║"
  echo "║                                                               ║"
  echo "║  1. A Telegram group with Topics enabled                     ║"
  echo "║  2. A bot — create via @BotFather (/newbot), add to group   ║"
  echo "║     as admin (needs: send messages, manage topics)           ║"
  echo "║  3. A topic for CTO — create one, e.g. \"CTO Factory\"       ║"
  echo "║  4. Topic link — open the topic, copy its URL:              ║"
  echo "║     https://t.me/c/XXXXXXXXX/YY                             ║"
  echo "║                                                               ║"
  echo "║  5. Your Telegram user ID — send /start to @userinfobot    ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo ""

  prompt_secret TELEGRAM_BOT_TOKEN "Bot Token (from @BotFather)"
  upsert_env "$OPENCLAW_HOME/.env" "TELEGRAM_BOT_TOKEN" "$TELEGRAM_BOT_TOKEN"

  # Parse topic link → group_id + topic_id
  if [ -z "$TELEGRAM_GROUP_ID" ] || [ -z "$TELEGRAM_TOPIC_ID" ]; then
    local topic_link=""
    echo ""
    echo "  Paste the Telegram topic link (e.g. https://t.me/c/3700389156/2):"
    read -r -p "  Link: " topic_link </dev/tty
    if [ -n "$topic_link" ]; then
      if parse_telegram_topic_link "$topic_link" "$TELEGRAM_BOT_TOKEN"; then
        info "Parsed: group=$TELEGRAM_GROUP_ID topic=$TELEGRAM_TOPIC_ID"
      else
        error "Could not parse link. Enter manually:"
        prompt_value TELEGRAM_GROUP_ID "Group ID (e.g. -1001234567890)"
        prompt_value TELEGRAM_TOPIC_ID "Topic ID (e.g. 42)"
      fi
    else
      prompt_value TELEGRAM_GROUP_ID "Group ID (e.g. -1001234567890)"
      prompt_value TELEGRAM_TOPIC_ID "Topic ID (e.g. 42)"
    fi
  fi

  prompt_value TELEGRAM_ALLOWED_USERS "Your Telegram user ID (from @userinfobot)"

  local users_json="$TELEGRAM_ALLOWED_USERS"

  # Update config with Telegram
  python3 - "$OPENCLAW_HOME/openclaw.json" "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_GROUP_ID" "$TELEGRAM_TOPIC_ID" "$users_json" << 'PYEOF'
import json, pathlib, sys
config_path = pathlib.Path(sys.argv[1])
bot_token, group_id, topic_id, allowed = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

d = json.loads(config_path.read_text())

tg = d.setdefault("channels", {}).setdefault("telegram", {})
tg["enabled"] = True
tg.setdefault("commands", {})["native"] = True
tg.setdefault("accounts", {}).setdefault("default", {})["botToken"] = "${TELEGRAM_BOT_TOKEN}"

plugins = d.setdefault("plugins", {})
allow = plugins.setdefault("allow", [])
if "telegram" not in allow:
    allow.append("telegram")

if group_id:
    groups = tg.setdefault("groups", {})
    group = groups.setdefault(group_id, {})
    if allowed:
        user_list = [u.strip() for u in allowed.split(",") if u.strip()]
        group["allowFrom"] = user_list
        tg["groupAllowFrom"] = user_list
    tg["groupPolicy"] = "allowlist"
    if topic_id:
        topics = group.setdefault("topics", {})
        topics.setdefault(topic_id, {"requireMention": False, "groupPolicy": "allowlist"})

config_path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYEOF

  info "Telegram configured (group: $TELEGRAM_GROUP_ID, topic: ${TELEGRAM_TOPIC_ID:-default})"
}

# ── Stage 6: Deploy CTO Factory ────────────────────────────

deploy_cto() {
  info "Deploying CTO Factory agent..."

  # Ensure rsync is available (may be missing on minimal installs)
  if ! command -v rsync >/dev/null 2>&1; then
    if [ "$(detect_os)" = "linux" ]; then
      run_root apt-get install -y -qq rsync 2>/dev/null || true
    fi
  fi
  command -v rsync >/dev/null 2>&1 || die "rsync is required but not found. Install it and retry."

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" EXIT

  git clone --depth 1 --branch "$CTO_BRANCH" "$CTO_REPO" "$tmp_dir/cto" 2>&1 | tail -1

  local dest="$OPENCLAW_HOME/workspace-factory"
  if [ -d "$dest" ]; then
    local backup="${dest}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    info "Backing up existing workspace to $backup"
    cp -r "$dest" "$backup"
  fi

  rsync -av --delete \
    --exclude='.cto-brain' --exclude='__pycache__' --exclude='.pytest_cache' \
    "$tmp_dir/cto/workspace-factory/" "$dest/" 2>&1 | tail -1

  chmod +x "$dest/scripts/"*.sh "$dest/scripts/"*.py 2>/dev/null || true

  # Register agent
  python3 "$dest/scripts/lobster_register_agent.py" \
    "$OPENCLAW_HOME/openclaw.json" \
    "cto-factory" \
    "$dest" \
    "${TELEGRAM_GROUP_ID:-}" \
    "${TELEGRAM_TOPIC_ID:-}"

  # Set model and tools
  python3 - "$OPENCLAW_HOME/openclaw.json" "$CTO_MODEL" "$CTO_FALLBACK" << 'PYEOF'
import json, sys
config_path, model, fallback = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.loads(open(config_path).read())
for a in d.get("agents",{}).get("list",[]):
    if a.get("id") == "cto-factory":
        a["model"] = {"primary": model, "fallbacks": [fallback]}
        a["default"] = True
        a.setdefault("tools", {})["alsoAllow"] = ["lobster"]
        a["tools"]["deny"] = ["cron"]
        break
plugins = d.setdefault("plugins", {})
allow = plugins.setdefault("allow", [])
if "lobster" not in allow:
    allow.append("lobster")
plugins.setdefault("entries", {})["lobster"] = {"enabled": True}
open(config_path, "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PYEOF

  local files
  files="$(find "$dest" -type f | wc -l | tr -d ' ')"
  info "CTO deployed ($files files)"

  # Install build monitor cron
  local monitor="$dest/scripts/build_monitor.sh"
  if [ -f "$monitor" ]; then
    chmod +x "$monitor"
    local cron_line="*/5 * * * * OPENCLAW_HOME=$OPENCLAW_HOME $monitor >/dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "build_monitor.sh"; then
      (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -
      info "Build monitor cron installed (every 5 min)"
    fi
  fi
}

# ── Stage 7: Validate + Restart ─────────────────────────────

finalize() {
  local os="$1"
  info "Validating config..."

  local valid
  valid="$(openclaw config validate --json 2>&1 | tail -1)"
  if echo "$valid" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('valid') else 1)" 2>/dev/null; then
    info "Config valid"
  else
    error "Config invalid:"
    echo "$valid"
    die "Fix config and re-run."
  fi

  info "Restarting gateway..."
  if [ "$os" = "macos" ]; then
    launchctl bootout "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
    sleep 2
    launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || openclaw gateway install 2>/dev/null || true
  else
    # Kill existing gateway
    if [ -f "$OPENCLAW_HOME/.gateway.pid" ]; then
      kill "$(cat "$OPENCLAW_HOME/.gateway.pid")" 2>/dev/null || true
      rm -f "$OPENCLAW_HOME/.gateway.pid"
    fi
    openclaw gateway stop 2>/dev/null || true
    sleep 2
    # Try systemd, fall back to foreground
    if ! openclaw gateway start 2>/dev/null; then
      mkdir -p "$OPENCLAW_HOME/logs"
      (
        cd "$OPENCLAW_HOME"
        export OPENCLAW_STATE_DIR="$OPENCLAW_HOME"
        export OPENCLAW_CONFIG_PATH="$OPENCLAW_HOME/openclaw.json"
        if [ -f "$OPENCLAW_HOME/.env" ]; then set -a; . "$OPENCLAW_HOME/.env"; set +a; fi
        nohup openclaw gateway run --port "$OPENCLAW_PORT" > "$OPENCLAW_HOME/logs/gateway.log" 2>&1 &
        echo $! > "$OPENCLAW_HOME/.gateway.pid"
      )
    fi
  fi
  sleep 5

  if openclaw gateway status 2>&1 | grep -q "probe: ok"; then
    info "Gateway running"
  else
    warn "Gateway probe failed. Start manually: openclaw gateway start"
  fi
}

# ── Main ────────────────────────────────────────────────────

main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║        CTO Factory Agent — Installer                    ║"
  echo "║        Lobster-first architecture                       ║"
  echo "║        Model: Claude Opus 4.6 (Anthropic OAuth)         ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""

  local os
  os="$(detect_os)"
  info "Detected OS: $os"

  info "Step 1/7: System dependencies"
  install_deps "$os"

  info "Step 2/7: OpenClaw + Lobster + Claude Code"
  install_tools "$os"

  info "Step 3/7: Anthropic authentication"
  setup_anthropic_auth

  info "Step 4/7: OpenClaw config + gateway"
  setup_openclaw "$os"

  info "Step 5/7: Telegram setup"
  setup_telegram

  info "Step 6/7: Deploy CTO Factory"
  deploy_cto

  info "Step 7/7: Validate + restart"
  finalize "$os"

  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  🎉 CTO Factory installed!                              ║"
  echo "║                                                         ║"
  echo "║  Test:                                                  ║"
  echo "║    openclaw agent --agent cto-factory --message 'hello' ║"
  echo "║                                                         ║"
  echo "║  Or talk to CTO in your Telegram group.                 ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
}

main "$@"
