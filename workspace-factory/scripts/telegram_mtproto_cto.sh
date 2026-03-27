#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/uladzislaupraskou/.openclaw/workspace-factory"
PY="$ROOT/.venv-telegram-mtproto/bin/python"
SCRIPT="$ROOT/scripts/telegram_mtproto_e2e.py"

CHAT_ID="${TELEGRAM_CTO_CHAT_ID:--1003633569118}"
TOPIC_TITLE="${TELEGRAM_CTO_TOPIC_TITLE:-CTO Lobster}"
EXPECT_FROM="${TELEGRAM_CTO_EXPECT_FROM:-OpenClaw SmartSpine}"
TIMEOUT_SEC="${TELEGRAM_CTO_TIMEOUT_SEC:-120}"

usage() {
  cat <<'EOF'
Usage:
  telegram_mtproto_cto.sh login
  telegram_mtproto_cto.sh topics
  telegram_mtproto_cto.sh new
  telegram_mtproto_cto.sh send "text"
  telegram_mtproto_cto.sh ask "text"

Env overrides:
  TELEGRAM_CTO_CHAT_ID
  TELEGRAM_CTO_TOPIC_TITLE
  TELEGRAM_CTO_EXPECT_FROM
  TELEGRAM_CTO_TIMEOUT_SEC
EOF
}

if [[ ! -x "$PY" ]]; then
  echo "missing venv: run $ROOT/scripts/setup_telegram_mtproto_env.sh" >&2
  exit 1
fi

cmd="${1:-help}"
shift || true

case "$cmd" in
  login|topics)
    exec "$PY" "$SCRIPT" \
      --chat-id "$CHAT_ID" \
      --list-topics \
      --json
    ;;
  new)
    exec "$PY" "$SCRIPT" \
      --chat-id "$CHAT_ID" \
      --topic-title "$TOPIC_TITLE" \
      --text "/new@openclaw_smartspine_bot" \
      --expect-from "$EXPECT_FROM" \
      --timeout-sec "$TIMEOUT_SEC" \
      --json
    ;;
  send)
    if [[ $# -eq 0 ]]; then
      echo "send requires message text" >&2
      exit 1
    fi
    exec "$PY" "$SCRIPT" \
      --chat-id "$CHAT_ID" \
      --topic-title "$TOPIC_TITLE" \
      --text "$*" \
      --json
    ;;
  ask)
    if [[ $# -eq 0 ]]; then
      echo "ask requires message text" >&2
      exit 1
    fi
    exec "$PY" "$SCRIPT" \
      --chat-id "$CHAT_ID" \
      --topic-title "$TOPIC_TITLE" \
      --text "$*" \
      --expect-from "$EXPECT_FROM" \
      --timeout-sec "$TIMEOUT_SEC" \
      --json
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
