# Telegram MTProto E2E

This is the user-account alternative to Telegram Web automation.

## Why use this

- Uses a real Telegram user account through MTProto.
- OpenClaw receives the message as a normal user inbound.
- No second bot is involved, so Telegram's bot-to-bot limitation does not apply.

## Secrets

The script reads credentials at runtime from:

```bash
/Users/uladzislaupraskou/tokenstg.json
```

Expected keys:

- `app_id`
- `app_hash`
- `phone`

The values do not need to be copied into the repo or chat.

## Setup

```bash
/Users/uladzislaupraskou/.openclaw/workspace-factory/scripts/setup_telegram_mtproto_env.sh
```

This creates:

```bash
/Users/uladzislaupraskou/.openclaw/workspace-factory/.venv-telegram-mtproto
```

## First login

On first run, the script will ask for:

1. Telegram login code
2. 2FA password, if enabled

The session is then stored locally at:

```bash
/Users/uladzislaupraskou/.openclaw/.telegram-mtproto/user.session
```

## Fast path for CTO topic

There is also a short wrapper for the current CTO topic:

```bash
/Users/uladzislaupraskou/.openclaw/workspace-factory/scripts/telegram_mtproto_cto.sh
```

Examples:

```bash
/Users/uladzislaupraskou/.openclaw/workspace-factory/scripts/telegram_mtproto_cto.sh login
/Users/uladzislaupraskou/.openclaw/workspace-factory/scripts/telegram_mtproto_cto.sh new
/Users/uladzislaupraskou/.openclaw/workspace-factory/scripts/telegram_mtproto_cto.sh ask "hello from mtproto"
```

Defaults baked into the wrapper:

- chat: `-1003633569118`
- topic: `CTO Lobster`
- expected agent reply sender: `OpenClaw SmartSpine`

## Examples

List topics in a forum chat:

```bash
/Users/uladzislaupraskou/.openclaw/workspace-factory/.venv-telegram-mtproto/bin/python \
  /Users/uladzislaupraskou/.openclaw/workspace-factory/scripts/telegram_mtproto_e2e.py \
  --chat-id -1003633569118 \
  --list-topics \
  --json
```

Send a message to a topic by title:

```bash
/Users/uladzislaupraskou/.openclaw/workspace-factory/.venv-telegram-mtproto/bin/python \
  /Users/uladzislaupraskou/.openclaw/workspace-factory/scripts/telegram_mtproto_e2e.py \
  --chat-id -1003633569118 \
  --topic-title "CTO Lobster" \
  --text "MTProto E2E ping" \
  --json
```

Send and wait for reply from a specific sender:

```bash
/Users/uladzislaupraskou/.openclaw/workspace-factory/.venv-telegram-mtproto/bin/python \
  /Users/uladzislaupraskou/.openclaw/workspace-factory/scripts/telegram_mtproto_e2e.py \
  --chat-id -1003633569118 \
  --topic-id 1269 \
  --text "/new@openclaw_smartspine_bot" \
  --expect-from "OpenClaw SmartSpine" \
  --timeout-sec 120 \
  --json
```

## Notes

- For forum topics, the script resolves by exact `--topic-title` or explicit `--topic-id`.
- The script uses Telethon and a normal user session, not the Bot API.
- I did not inspect the secrets file; the script loads it only when you run it locally.
