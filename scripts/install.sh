#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# CTO Factory Agent — One-Script Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/no-name-labs/cto-lobster/main/scripts/install.sh | bash
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
TELEGRAM_ALLOWED_USER_ID="${TELEGRAM_ALLOWED_USER_ID:-}"
BIND_TELEGRAM_LINK="${BIND_TELEGRAM_LINK:-}"
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
  # Flush tty input buffer
  read -r -t 0.1 -n 10000 </dev/tty 2>/dev/null || true
  local entered=""
  if [ "$optional" = "true" ]; then
    read -r -p "$prompt_text (optional, Enter to skip): " entered </dev/tty
  else
    while [ -z "$entered" ]; do
      read -r -p "$prompt_text: " entered </dev/tty
    done
  fi
  printf -v "$var_name" "%s" "$entered"
}

prompt_secret() {
  local var_name="$1" prompt_text="$2"
  local current="${!var_name:-}"
  [ -n "$current" ] && return 0
  if [ "$NON_INTERACTIVE" = "true" ]; then
    die "Missing required: $var_name (NON_INTERACTIVE=true)"
  fi
  # Flush tty input buffer (previous commands may leave garbage)
  read -r -t 0.1 -n 10000 </dev/tty 2>/dev/null || true
  local entered=""
  while [ -z "$entered" ]; do
    read -r -s -p "$prompt_text: " entered </dev/tty; echo
  done
  printf -v "$var_name" "%s" "$entered"
}

wait_for_user() {
  [ "$NON_INTERACTIVE" = "true" ] && return 0
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

with_openclaw_env() {
  export OPENCLAW_STATE_DIR="$OPENCLAW_HOME"
  export OPENCLAW_CONFIG_PATH="$OPENCLAW_HOME/openclaw.json"
  if [ -f "$OPENCLAW_HOME/.env" ]; then set -a; . "$OPENCLAW_HOME/.env"; set +a; fi
  "$@"
}

stop_gateway() {
  with_openclaw_env openclaw gateway stop >/dev/null 2>&1 || true
  sleep 1
  if [ -f "$OPENCLAW_HOME/.gateway.pid" ]; then
    kill "$(cat "$OPENCLAW_HOME/.gateway.pid")" 2>/dev/null || true
    rm -f "$OPENCLAW_HOME/.gateway.pid"
  fi
}

start_gateway() {
  stop_gateway || true
  mkdir -p "$OPENCLAW_HOME/logs"
  (
    cd "$OPENCLAW_HOME"
    export OPENCLAW_STATE_DIR="$OPENCLAW_HOME"
    export OPENCLAW_CONFIG_PATH="$OPENCLAW_HOME/openclaw.json"
    if [ -f "$OPENCLAW_HOME/.env" ]; then set -a; . "$OPENCLAW_HOME/.env"; set +a; fi
    nohup openclaw gateway run --port "$OPENCLAW_PORT" > "$OPENCLAW_HOME/logs/gateway-run.log" 2>&1 &
    echo $! > "$OPENCLAW_HOME/.gateway.pid"
  )
}

wait_gateway_healthy() {
  local timeout="${1:-60}" start
  start="$(date +%s)"
  while true; do
    if with_openclaw_env openclaw health --json >/dev/null 2>&1; then return 0; fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then return 1; fi
    sleep 2
  done
}

detect_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "macos" ;;
    *)       die "Unsupported OS: $(uname -s)" ;;
  esac
}

save_auth_token() {
  local token="$1"
  # Save to workspace-factory (CTO agent reads from here)
  local auth_store="$OPENCLAW_HOME/workspace-factory/auth-profiles.json"
  mkdir -p "$(dirname "$auth_store")"
  python3 - "$auth_store" "$token" << 'PYEOF'
import json, pathlib, sys, time
p = pathlib.Path(sys.argv[1]); t = sys.argv[2].strip()
p.parent.mkdir(parents=True, exist_ok=True)
d = json.loads(p.read_text()) if p.exists() else {}
d["version"] = 1
d.setdefault("profiles", {})["anthropic:oauth"] = {
    "type": "token", "provider": "anthropic", "token": t,
    "expires": int(time.time() * 1000) + 365*24*60*60*1000}
p.write_text(json.dumps(d, indent=2) + "\n")
PYEOF
  # Also save to agents/main/agent/ (some OpenClaw versions look here)
  local main_auth="$OPENCLAW_HOME/agents/main/agent/auth-profiles.json"
  mkdir -p "$(dirname "$main_auth")"
  cp "$auth_store" "$main_auth" 2>/dev/null || true
}

# ── Parse Telegram topic link ───────────────────────────────

parse_telegram_topic_link() {
  local link="$1" token="$2"
  local parsed
  parsed="$(python3 - "$link" "$token" << 'PYEOF'
import json, re, sys
from urllib.parse import urlparse
raw = (sys.argv[1] or "").strip()
bot_token = (sys.argv[2] or "").strip()
if not raw: raise SystemExit("Link is empty.")
if not re.match(r"^https?://", raw, flags=re.I): raw = "https://" + raw
parsed = urlparse(raw)
host = parsed.netloc.lower()
if host not in {"t.me", "www.t.me", "telegram.me", "www.telegram.me"}:
    raise SystemExit("Unsupported Telegram host.")
parts = [p for p in parsed.path.split("/") if p]
if len(parts) < 2: raise SystemExit("Invalid link format.")
group_id = ""; topic_id = ""
if parts[0] == "c":
    if len(parts) < 3: raise SystemExit("Missing topic ID in t.me/c link.")
    topic_id = parts[2]
    if parts[1].isdigit(): group_id = f"-100{parts[1]}"
    else: raise SystemExit("Use numeric t.me/c/<number>/<topic> link.")
else:
    username = parts[0]; topic_id = parts[1]
    if not bot_token: raise SystemExit("Username link requires bot token. Use t.me/c/<number>/<topic>.")
    from urllib.request import Request, urlopen
    url = f"https://api.telegram.org/bot{bot_token}/getChat?chat_id=@{username}"
    with urlopen(Request(url, headers={"Accept": "application/json"}), timeout=15) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if not payload.get("ok"): raise SystemExit(payload.get("description", "getChat failed"))
    group_id = str(payload["result"]["id"])
if not topic_id.isdigit(): raise SystemExit("Topic ID must be numeric.")
print(json.dumps({"group_id": group_id, "topic_id": topic_id}))
PYEOF
)" || return 1
  TELEGRAM_GROUP_ID="$(printf "%s" "$parsed" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['group_id'])")"
  TELEGRAM_TOPIC_ID="$(printf "%s" "$parsed" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['topic_id'])")"
}

# ── Allow user in all Telegram allowlists ───────────────────

allow_group_user() {
  local uid="$1"
  [ -z "$uid" ] && return 0
  python3 - "$OPENCLAW_HOME/openclaw.json" "$uid" << 'PYEOF'
import json, pathlib, sys
config_path = pathlib.Path(sys.argv[1])
uid = str(sys.argv[2]).strip()
if not uid: exit(0)
data = json.loads(config_path.read_text())
tg = data.setdefault("channels", {}).setdefault("telegram", {})
tg.setdefault("groupPolicy", "allowlist")
ga = {str(x).strip() for x in tg.get("groupAllowFrom", []) if str(x).strip()}
ga.add(uid); tg["groupAllowFrom"] = sorted(ga)
acc = tg.setdefault("accounts", {}).setdefault("default", {})
acc.setdefault("groupPolicy", "allowlist")
aa = {str(x).strip() for x in acc.get("groupAllowFrom", []) if str(x).strip()}
aa.add(uid); acc["groupAllowFrom"] = sorted(aa)
groups = tg.get("groups", {})
if isinstance(groups, dict):
    for _, g in groups.items():
        if isinstance(g, dict):
            al = {str(x).strip() for x in g.get("allowFrom", []) if str(x).strip()}
            al.add(uid); g["allowFrom"] = sorted(al)
            for _, t in g.get("topics", {}).items():
                if isinstance(t, dict):
                    ta = {str(x).strip() for x in t.get("allowFrom", []) if str(x).strip()}
                    ta.add(uid); t["allowFrom"] = sorted(ta)
config_path.write_text(json.dumps(data, indent=2) + "\n")
PYEOF
  info "Added user $uid to all Telegram allowlists"
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
    run_root apt-get install -y -qq git python3 curl jq rsync cron
  elif [ "$os" = "macos" ]; then
    command -v node >/dev/null 2>&1 || { command -v brew >/dev/null 2>&1 && brew install node || die "Install Node.js"; }
    for cmd in git python3 curl jq; do command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd"; done
  fi
  info "Node $(node --version), Python $(python3 --version | awk '{print $2}')"
}

# ── Stage 2: OpenClaw + Lobster + Claude Code ───────────────

install_tools() {
  local os="$1"
  for pkg_cmd in "openclaw:openclaw@latest" "lobster:@clawdbot/lobster" "claude:@anthropic-ai/claude-code"; do
    local cmd="${pkg_cmd%%:*}" pkg="${pkg_cmd##*:}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      info "Installing $cmd..."
      if [ "$os" = "linux" ]; then run_root npm install -g "$pkg"; else npm install -g "$pkg"; fi
    else
      info "$cmd already installed"
    fi
  done
}

# ── Stage 3: Anthropic OAuth ────────────────────────────────

setup_anthropic_auth() {
  info "Setting up Anthropic authentication..."
  if claude auth status >/dev/null 2>&1; then
    info "Claude Code already authenticated."
    return 0
  fi
  if [ "$NON_INTERACTIVE" = "true" ]; then
    warn "Non-interactive: skipping auth. Run 'claude setup-token' manually."
    return 0
  fi

  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  Anthropic Authentication                                    ║"
  echo "║                                                               ║"
  echo "║  1. A URL will appear — open it in your browser             ║"
  echo "║  2. Sign in to Anthropic                                     ║"
  echo "║  3. Copy the token (sk-ant-oat...) and paste it back here   ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo ""

  local captured_token=""

  # Try auto-capture via script(1)
  local setup_log
  setup_log="$(mktemp)"
  if command -v script >/dev/null 2>&1; then
    script -q -e -c "claude setup-token" "$setup_log" </dev/tty >/dev/tty 2>&1 || true
    captured_token="$(tr -d '\r' < "$setup_log" | sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g' | awk '
      BEGIN{c=0;t=""} {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0);
      if(c==1){if($0~/^[A-Za-z0-9._-]+$/){t=t$0;next}c=0}
      if($0~/^sk-ant-oat[A-Za-z0-9._-]*$/){t=$0;c=1;next}}
      END{if(t!="")print t}' | tail -1 || true)"
  else
    claude setup-token </dev/tty >/dev/tty 2>&1 || true
  fi
  rm -f "$setup_log"

  # If auto-capture failed, ask for manual paste (up to 3 attempts)
  local attempt=0
  while [ -z "$captured_token" ] || ! echo "$captured_token" | grep -qE '^sk-ant-oat[A-Za-z0-9._-]+$'; do
    attempt=$((attempt + 1))
    [ "$attempt" -gt 3 ] && break
    echo ""
    echo "  Token not detected automatically."
    echo "  If you see a token starting with sk-ant-oat... in the output above,"
    echo "  paste it here. Or run 'claude setup-token' in another terminal"
    echo "  and paste the token."
    echo ""
    read -r -s -p "  Paste token (sk-ant-oat...): " captured_token </dev/tty; echo
    captured_token="$(echo "$captured_token" | tr -d '\r\n ' | sed 's/^export //' | sed 's/^CLAUDE_CODE_OAUTH_TOKEN=//')"
  done

  # Save token everywhere OpenClaw might look
  if echo "$captured_token" | grep -qE '^sk-ant-oat[A-Za-z0-9._-]+$'; then
    info "Saving Anthropic token..."
    # 1. auth-profiles.json (agent-level auth store)
    save_auth_token "$captured_token"
    # 2. CLAUDE_CODE_OAUTH_TOKEN in .env (Claude Code CLI picks this up)
    upsert_env "$OPENCLAW_HOME/.env" "CLAUDE_CODE_OAUTH_TOKEN" "$captured_token"
    # 3. Verify it works
    local probe
    probe="$(CLAUDE_CODE_OAUTH_TOKEN="$captured_token" claude -p "Reply exactly: AUTH_OK" --output-format text --permission-mode default 2>&1 || true)"
    if echo "$probe" | grep -q "AUTH_OK"; then
      info "Anthropic auth verified — Claude responds."
    else
      warn "Token saved but Claude probe failed. It may still work through OpenClaw."
    fi
  else
    warn "No valid token. Agent won't work until you configure auth."
    warn "Run: claude setup-token"
    warn "Then: echo 'CLAUDE_CODE_OAUTH_TOKEN=<your-token>' >> $OPENCLAW_HOME/.env"
  fi
}

# ── Stage 4: OpenClaw Config + Gateway ──────────────────────

setup_openclaw() {
  info "Configuring OpenClaw..."
  mkdir -p "$OPENCLAW_HOME"

  # Gateway token
  local gw_token=""
  gw_token="$(grep 'OPENCLAW_GATEWAY_TOKEN=' "$OPENCLAW_HOME/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  [ -z "$gw_token" ] && gw_token="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"

  upsert_env "$OPENCLAW_HOME/.env" "OPENCLAW_GATEWAY_TOKEN" "$gw_token"
  upsert_env "$OPENCLAW_HOME/.env" "OPENCLAW_PORT" "$OPENCLAW_PORT"
  upsert_env "$OPENCLAW_HOME/.env" "OPENCLAW_CODE_AGENT_CLI" "claude"

  # Create/update openclaw.json
  python3 - "$OPENCLAW_HOME/openclaw.json" "$OPENCLAW_PORT" "$gw_token" << 'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); port = int(sys.argv[2]); token = sys.argv[3]
d = json.loads(p.read_text()) if p.exists() else {}
d.setdefault("gateway", {}).update({"port": port, "mode": "local", "bind": "loopback"})
d["gateway"].setdefault("auth", {"mode": "token", "token": token})
auth = d.setdefault("auth", {})
profiles = auth.setdefault("profiles", {})
profiles.setdefault("anthropic:oauth", {"provider": "anthropic", "mode": "token"})
order = auth.setdefault("order", {})
prov_order = order.setdefault("anthropic", [])
if "anthropic:oauth" not in prov_order: prov_order.append("anthropic:oauth")
agents = d.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
defaults.setdefault("model", {"primary": "anthropic/claude-sonnet-4-6"})
defaults.setdefault("timeoutSeconds", 3600)
agent_list = agents.setdefault("list", [])
# Ensure main agent exists (OpenClaw requires it)
if not any(a.get("id") == "main" for a in agent_list):
    import os
    agent_list.append({
        "id": "main", "default": True, "name": "Main Agent",
        "workspace": os.path.expanduser("~/.openclaw/workspace"),
        "agentDir": os.path.expanduser("~/.openclaw/agents/main/agent"),
    })
d.setdefault("bindings", [])
d.setdefault("plugins", {}).setdefault("allow", [])
p.write_text(json.dumps(d, indent=2) + "\n")
PYEOF

  # Start gateway
  info "Starting gateway..."
  start_gateway
  sleep 5
  if wait_gateway_healthy 60; then
    info "Gateway running (port $OPENCLAW_PORT)"
  else
    warn "Gateway not healthy yet. Check: $OPENCLAW_HOME/logs/gateway-run.log"
  fi
}

# ── Stage 5: Telegram — plugin + pairing + binding ──────────

setup_telegram() {
  info "Setting up Telegram..."

  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  Telegram Setup                                              ║"
  echo "║                                                               ║"
  echo "║  You need:                                                   ║"
  echo "║  1. A bot — create via @BotFather, add to your group        ║"
  echo "║     as admin (send messages + manage topics)                 ║"
  echo "║  2. A group with Topics enabled, a topic for CTO            ║"
  echo "║  3. Topic link: open topic → copy URL                       ║"
  echo "║     Example: https://t.me/c/3700389156/2                    ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo ""

  # 1. Bot token (validate format: numeric_id:alphanumeric)
  while true; do
    prompt_secret TELEGRAM_BOT_TOKEN "Bot Token (from @BotFather)"
    if echo "$TELEGRAM_BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
      break
    fi
    error "Invalid bot token format. Must be like: 1234567890:ABCdefGHI..."
    error "Create a bot via @BotFather in Telegram and copy the token."
    TELEGRAM_BOT_TOKEN=""
  done
  upsert_env "$OPENCLAW_HOME/.env" "TELEGRAM_BOT_TOKEN" "$TELEGRAM_BOT_TOKEN"

  # 2. Enable Telegram plugin
  info "Enabling Telegram plugin..."
  with_openclaw_env openclaw plugins enable telegram >/dev/null 2>&1 || true

  # 3. Add Telegram channel
  info "Configuring Telegram channel..."
  with_openclaw_env openclaw channels add --channel telegram --account default --token "$TELEGRAM_BOT_TOKEN" >/dev/null 2>&1 || true

  # 4. Write bot token to config
  python3 - "$OPENCLAW_HOME/openclaw.json" "$TELEGRAM_BOT_TOKEN" << 'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); t = sys.argv[2]
d = json.loads(p.read_text())
tg = d.setdefault("channels", {}).setdefault("telegram", {})
tg["enabled"] = True
tg.setdefault("commands", {})["native"] = True
tg.setdefault("accounts", {}).setdefault("default", {})["botToken"] = t
plugins = d.setdefault("plugins", {})
allow = plugins.setdefault("allow", [])
if "telegram" not in allow: allow.append("telegram")
p.write_text(json.dumps(d, indent=2) + "\n")
PYEOF

  # 5. Restart gateway with Telegram
  info "Restarting gateway with Telegram..."
  start_gateway
  sleep 3
  if ! wait_gateway_healthy 90; then
    die "Gateway health check failed after Telegram setup."
  fi

  # 6. Pairing — user sends message to bot, we approve
  echo ""
  echo "  Now pair your Telegram account with the bot:"
  echo "  1. Open a DM with your bot in Telegram"
  echo "  2. Send any message (e.g. 'hello')"
  echo "  3. The bot will reply with 'pairing required'"
  echo "  4. Come back here and press Enter"
  echo ""
  wait_for_user "Press Enter after sending a message to the bot... "

  info "Looking for pairing request..."
  local pairing_code="" paired_uid="" pending=""
  local deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pending="$(with_openclaw_env openclaw pairing list --channel telegram --json 2>/dev/null || with_openclaw_env openclaw pairing list telegram --json 2>/dev/null || true)"
    if [ -n "$pending" ]; then
      pairing_code="$(printf "%s" "$pending" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
reqs=d if isinstance(d,list) else d.get('requests',d.get('pending',[]))
if isinstance(reqs,list) and reqs: print(reqs[0].get('code',''))
" 2>/dev/null || true)"
      paired_uid="$(printf "%s" "$pending" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
reqs=d if isinstance(d,list) else d.get('requests',d.get('pending',[]))
if isinstance(reqs,list) and reqs: print(reqs[0].get('id',''))
" 2>/dev/null || true)"
      [ -n "$pairing_code" ] && break
    fi
    sleep 2
  done

  if [ -z "$pairing_code" ]; then
    warn "No pairing request found. Manual fallback:"
    echo "  Run: openclaw pairing approve telegram <CODE>"
    prompt_value TELEGRAM_ALLOWED_USER_ID "Enter your Telegram user ID manually"
  else
    info "Approving pairing (code: $pairing_code)..."
    with_openclaw_env openclaw pairing approve telegram "$pairing_code" --notify >/dev/null 2>&1 || true
    TELEGRAM_ALLOWED_USER_ID="$paired_uid"
    info "Paired Telegram user: $paired_uid"
  fi

  # 7. Add user to allowlists
  if [ -n "$TELEGRAM_ALLOWED_USER_ID" ]; then
    allow_group_user "$TELEGRAM_ALLOWED_USER_ID"
  fi

  # 8. Topic binding — paste link
  if [ -z "$TELEGRAM_GROUP_ID" ] || [ -z "$TELEGRAM_TOPIC_ID" ]; then
    if [ -n "$BIND_TELEGRAM_LINK" ]; then
      parse_telegram_topic_link "$BIND_TELEGRAM_LINK" "$TELEGRAM_BOT_TOKEN" || die "Failed to parse link"
    else
      echo ""
      echo "  Paste the Telegram topic link for CTO:"
      echo "  Example: https://t.me/c/3700389156/2"
      local link=""
      read -r -p "  Link: " link </dev/tty
      if [ -n "$link" ]; then
        if parse_telegram_topic_link "$link" "$TELEGRAM_BOT_TOKEN"; then
          info "Parsed: group=$TELEGRAM_GROUP_ID topic=$TELEGRAM_TOPIC_ID"
          upsert_env "$OPENCLAW_HOME/.env" "BIND_TELEGRAM_LINK" "$link"
        else
          error "Could not parse link."
          prompt_value TELEGRAM_GROUP_ID "Group ID (e.g. -1001234567890)"
          prompt_value TELEGRAM_TOPIC_ID "Topic ID"
        fi
      else
        prompt_value TELEGRAM_GROUP_ID "Group ID (e.g. -1001234567890)"
        prompt_value TELEGRAM_TOPIC_ID "Topic ID"
      fi
    fi
  fi

  upsert_env "$OPENCLAW_HOME/.env" "BIND_GROUP_ID" "$TELEGRAM_GROUP_ID"
  upsert_env "$OPENCLAW_HOME/.env" "BIND_TOPIC_ID" "$TELEGRAM_TOPIC_ID"

  # 9. Configure group + topic in openclaw.json
  python3 - "$OPENCLAW_HOME/openclaw.json" "$TELEGRAM_GROUP_ID" "$TELEGRAM_TOPIC_ID" "$TELEGRAM_ALLOWED_USER_ID" << 'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
gid, tid, uid = sys.argv[2], sys.argv[3], sys.argv[4]
d = json.loads(p.read_text())
tg = d.setdefault("channels", {}).setdefault("telegram", {})
if gid:
    groups = tg.setdefault("groups", {})
    g = groups.setdefault(gid, {})
    if uid:
        allow = list({str(x) for x in g.get("allowFrom", [])})
        if uid not in allow: allow.append(uid)
        g["allowFrom"] = allow
    if tid:
        topics = g.setdefault("topics", {})
        t = topics.setdefault(tid, {})
        t["requireMention"] = False
        t["groupPolicy"] = "allowlist"
        if uid:
            ta = list({str(x) for x in t.get("allowFrom", [])})
            if uid not in ta: ta.append(uid)
            t["allowFrom"] = ta
p.write_text(json.dumps(d, indent=2) + "\n")
PYEOF

  info "Telegram configured (group: $TELEGRAM_GROUP_ID, topic: $TELEGRAM_TOPIC_ID)"
}

# ── Stage 6: Deploy CTO Factory ────────────────────────────

deploy_cto() {
  info "Deploying CTO Factory agent..."
  command -v rsync >/dev/null 2>&1 || { [ "$(detect_os)" = "linux" ] && run_root apt-get install -y -qq rsync 2>/dev/null || true; }
  command -v rsync >/dev/null 2>&1 || die "rsync required"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" EXIT

  git clone --depth 1 --branch "$CTO_BRANCH" "$CTO_REPO" "$tmp_dir/cto" 2>&1 | tail -1

  local dest="$OPENCLAW_HOME/workspace-factory"
  [ -d "$dest" ] && cp -r "$dest" "${dest}.backup.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true

  rsync -av --delete \
    --exclude='.cto-brain' --exclude='__pycache__' --exclude='.pytest_cache' \
    "$tmp_dir/cto/workspace-factory/" "$dest/" 2>&1 | tail -1

  chmod +x "$dest/scripts/"*.sh "$dest/scripts/"*.py 2>/dev/null || true

  # Register CTO agent with binding
  python3 "$dest/scripts/lobster_register_agent.py" \
    "$OPENCLAW_HOME/openclaw.json" "cto-factory" "$dest" \
    "${TELEGRAM_GROUP_ID:-}" "${TELEGRAM_TOPIC_ID:-}"

  # Set model, tools, plugins
  python3 - "$OPENCLAW_HOME/openclaw.json" "$CTO_MODEL" "$CTO_FALLBACK" << 'PYEOF'
import json, sys
p, model, fb = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.loads(open(p).read())
for a in d.get("agents",{}).get("list",[]):
    if a.get("id") == "cto-factory":
        a["model"] = {"primary": model, "fallbacks": [fb]}
        a["default"] = True
        a.setdefault("tools", {})["alsoAllow"] = ["lobster"]
        a["tools"]["deny"] = ["cron"]
        break
plugins = d.setdefault("plugins", {})
allow = plugins.setdefault("allow", [])
for p_name in ["lobster", "telegram"]:
    if p_name not in allow: allow.append(p_name)
plugins.setdefault("entries", {})["lobster"] = {"enabled": True}
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PYEOF

  info "CTO deployed ($(find "$dest" -type f | wc -l | tr -d ' ') files)"

  # Build monitor cron
  local monitor="$dest/scripts/build_monitor.sh"
  if [ -f "$monitor" ] && command -v crontab >/dev/null 2>&1; then
    chmod +x "$monitor"
    # Start cron daemon if not running (containers)
    if [ "$(detect_os)" = "linux" ]; then
      service cron start 2>/dev/null || cron 2>/dev/null || true
    fi
    local cron_line="*/5 * * * * OPENCLAW_HOME=$OPENCLAW_HOME $monitor >/dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "build_monitor.sh"; then
      (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -
      info "Build monitor cron installed"
    fi
  fi
}

# ── Stage 7: Validate + Final Restart ───────────────────────

finalize() {
  info "Validating config..."
  local valid
  valid="$(with_openclaw_env openclaw config validate --json 2>&1 | tail -1)"
  if echo "$valid" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get('valid') else 1)" 2>/dev/null; then
    info "Config valid"
  else
    warn "Config validation issue:"
    echo "$valid"
  fi

  info "Final gateway restart..."
  start_gateway
  sleep 5
  if wait_gateway_healthy 60; then
    info "Gateway healthy"
  else
    warn "Gateway not healthy. Check: $OPENCLAW_HOME/logs/gateway-run.log"
  fi
}

# ── Main ────────────────────────────────────────────────────

main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║        CTO Factory Agent — Installer                    ║"
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
  setup_openclaw

  info "Step 5/7: Telegram setup + pairing"
  setup_telegram

  info "Step 6/7: Deploy CTO Factory"
  deploy_cto

  info "Step 7/7: Validate + restart"
  finalize

  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  🎉 CTO Factory installed!                              ║"
  echo "║                                                         ║"
  echo "║  Test:                                                  ║"
  echo "║    openclaw agent --agent cto-factory --message 'hello' ║"
  echo "║                                                         ║"
  echo "║  Or talk to CTO in your Telegram topic.                 ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
}

main "$@"
