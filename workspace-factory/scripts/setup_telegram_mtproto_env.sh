#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/uladzislaupraskou/.openclaw/workspace-factory"
VENV="$ROOT/.venv-telegram-mtproto"

python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install "telethon==1.42.0"

echo "ready: $VENV"
