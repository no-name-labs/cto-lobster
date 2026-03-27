#!/usr/bin/env python3
"""Minimal MTProto E2E harness for Telegram forum topics.

This script intentionally reads credentials only at runtime from a local JSON
file, so the values never need to be echoed back into the workspace or chat.
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import json
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from telethon import TelegramClient, functions, errors
DEFAULT_CREDS = Path("/Users/uladzislaupraskou/tokenstg.json")
DEFAULT_SESSION = Path("/Users/uladzislaupraskou/.openclaw/.telegram-mtproto/user")


@dataclass
class Creds:
    api_id: int
    api_hash: str
    phone: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Telegram MTProto topic sender for OpenClaw E2E.")
    parser.add_argument("--creds-json", default=str(DEFAULT_CREDS), help="Path to JSON with app_id/app_hash/phone.")
    parser.add_argument("--session", default=str(DEFAULT_SESSION), help="Telethon session path.")
    parser.add_argument("--chat-id", type=int, help="Numeric Telegram chat ID, e.g. -1001234567890.")
    parser.add_argument("--chat", help="Alternative entity reference, e.g. username or invite-resolved title.")
    parser.add_argument("--topic-id", type=int, help="Forum topic/thread ID.")
    parser.add_argument("--topic-title", help="Resolve a topic ID by exact forum topic title.")
    parser.add_argument("--text", help="Message text to send.")
    parser.add_argument("--expect-from", help="Wait for a reply from this sender username/title/id.")
    parser.add_argument("--timeout-sec", type=int, default=90, help="Reply wait timeout.")
    parser.add_argument("--poll-sec", type=float, default=2.0, help="Polling interval while waiting.")
    parser.add_argument("--list-topics", action="store_true", help="List forum topics for the target chat.")
    parser.add_argument("--limit", type=int, default=50, help="Topic listing limit.")
    parser.add_argument("--json", action="store_true", help="Emit JSON result.")
    return parser.parse_args()


def emit(payload: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(payload)


def load_creds(path: str) -> Creds:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    missing = [key for key in ("app_id", "app_hash", "phone") if not raw.get(key)]
    if missing:
        raise ValueError(f"Missing required keys in creds JSON: {', '.join(missing)}")
    return Creds(api_id=int(raw["app_id"]), api_hash=str(raw["app_hash"]), phone=str(raw["phone"]))


async def ensure_authorized(client: TelegramClient, phone: str) -> None:
    await client.connect()
    if await client.is_user_authorized():
        return

    sent = await client.send_code_request(phone)
    code = input("Telegram login code: ").strip()
    try:
        await client.sign_in(phone=phone, code=code, phone_code_hash=sent.phone_code_hash)
    except errors.SessionPasswordNeededError:
        password = getpass.getpass("Telegram 2FA password: ")
        await client.sign_in(password=password)


async def resolve_chat(client: TelegramClient, chat_id: int | None, chat: str | None):
    if chat_id is not None:
        return await client.get_entity(chat_id)
    if chat:
        return await client.get_entity(chat)
    raise ValueError("Provide either --chat-id or --chat")


async def list_topics(client: TelegramClient, peer: Any, limit: int, query: str | None = None) -> list[dict[str, Any]]:
    result = await client(
        functions.messages.GetForumTopicsRequest(
            peer=peer,
            offset_date=datetime.fromtimestamp(0, tz=timezone.utc),
            offset_id=0,
            offset_topic=0,
            limit=limit,
            q=query or None,
        )
    )
    rows = []
    for topic in getattr(result, "topics", []):
        title = getattr(topic, "title", None)
        if not title:
            continue
        rows.append(
            {
                "id": getattr(topic, "id", None),
                "title": title,
                "top_message": getattr(topic, "top_message", None),
                "unread_count": getattr(topic, "unread_count", None),
            }
        )
    return rows


async def resolve_topic_id(
    client: TelegramClient,
    peer: Any,
    topic_id: int | None,
    topic_title: str | None,
    limit: int,
) -> tuple[int | None, int | None, str | None]:
    if topic_id is not None:
        result = await client(functions.messages.GetForumTopicsByIDRequest(peer=peer, topics=[topic_id]))
        for topic in getattr(result, "topics", []):
            title = getattr(topic, "title", None)
            if title:
                return topic_id, getattr(topic, "top_message", None), title
        raise ValueError(f"Topic ID {topic_id} not found in target chat")

    if topic_title:
        topics = await list_topics(client, peer, limit=limit, query=topic_title)
        exact = [row for row in topics if row["title"] == topic_title]
        if not exact:
            raise ValueError(f'Topic titled "{topic_title}" not found')
        if len(exact) > 1:
            raise ValueError(f'Ambiguous topic title "{topic_title}" ({len(exact)} matches)')
        return exact[0]["id"], exact[0]["top_message"], exact[0]["title"]

    return None, None, None


async def fetch_topic_messages(client: TelegramClient, peer: Any, topic_id: int, limit: int = 20) -> list[Any]:
    # Forum-topic reads are more reliable when we fetch recent chat messages
    # and filter by topic markers, rather than relying on GetRepliesRequest.
    messages = await client.get_messages(peer, limit=max(limit * 4, 50))
    result = []
    for message in messages:
        reply = getattr(message, "reply_to", None)
        reply_to_msg_id = getattr(reply, "reply_to_msg_id", None)
        reply_to_top_id = getattr(reply, "reply_to_top_id", None)
        if reply_to_top_id == topic_id or reply_to_msg_id == topic_id:
            result.append(message)
    return result[:limit]


def sender_matches(message: Any, expected: str | None) -> bool:
    if not expected:
        return not bool(getattr(message, "out", False))
    expected_norm = expected.strip().lower()
    sender_id = getattr(message, "sender_id", None)
    if sender_id is not None and expected_norm == str(sender_id).lower():
        return True

    sender = getattr(message, "sender", None)
    candidates = []
    username = getattr(sender, "username", None)
    if username:
        candidates.append(username)
    first_name = getattr(sender, "first_name", None)
    last_name = getattr(sender, "last_name", None)
    full_name = " ".join(part for part in (first_name, last_name) if part)
    if full_name:
        candidates.append(full_name)
    title = getattr(sender, "title", None)
    if title:
        candidates.append(title)

    return any(expected_norm == value.strip().lower() for value in candidates if value)


def message_to_dict(message: Any) -> dict[str, Any]:
    sender = getattr(message, "sender", None)
    sender_name = None
    if sender is not None:
        sender_name = (
            getattr(sender, "title", None)
            or getattr(sender, "username", None)
            or " ".join(part for part in (getattr(sender, "first_name", None), getattr(sender, "last_name", None)) if part)
            or None
        )
    return {
        "id": getattr(message, "id", None),
        "text": getattr(message, "message", None),
        "date": getattr(message, "date", None).isoformat() if getattr(message, "date", None) else None,
        "out": bool(getattr(message, "out", False)),
        "sender_id": getattr(message, "sender_id", None),
        "sender_name": sender_name,
    }


async def send_to_topic(
    client: TelegramClient,
    peer: Any,
    topic_root_message_id: int | None,
    text: str,
) -> Any:
    if topic_root_message_id is None:
        return await client.send_message(peer, text)
    # Inference from Telegram threads API + Telethon TL docs:
    # posting into a forum topic is done by replying to the topic's root/top message.
    return await client.send_message(peer, text, reply_to=topic_root_message_id)


async def wait_for_reply(
    client: TelegramClient,
    peer: Any,
    topic_id: int | None,
    sent_id: int,
    expect_from: str | None,
    timeout_sec: int,
    poll_sec: float,
) -> Any | None:
    deadline = time.monotonic() + timeout_sec
    seen: set[int] = {sent_id}
    while time.monotonic() < deadline:
        if topic_id is None:
            messages = await client.get_messages(peer, limit=20)
        else:
            messages = await fetch_topic_messages(client, peer, topic_id, limit=30)
        for message in sorted(messages, key=lambda item: item.id or 0):
            message_id = getattr(message, "id", None)
            if message_id is None or message_id in seen:
                continue
            if message_id <= sent_id:
                seen.add(message_id)
                continue
            seen.add(message_id)
            if getattr(message, "out", False):
                continue
            if sender_matches(message, expect_from):
                return message
        await asyncio.sleep(poll_sec)
    return None


async def async_main() -> int:
    args = parse_args()
    creds = load_creds(args.creds_json)

    session_path = Path(args.session).expanduser()
    session_path.parent.mkdir(parents=True, exist_ok=True)

    client = TelegramClient(str(session_path), creds.api_id, creds.api_hash)
    await ensure_authorized(client, creds.phone)

    try:
        peer = await resolve_chat(client, args.chat_id, args.chat)

        if args.list_topics:
            rows = await list_topics(client, peer, limit=args.limit, query=args.topic_title)
            emit({"ok": True, "topics": rows}, args.json)
            return 0

        if not args.text:
            raise ValueError("--text is required unless --list-topics is used")

        topic_id, topic_root_message_id, topic_title = await resolve_topic_id(
            client, peer, args.topic_id, args.topic_title, args.limit
        )
        sent = await send_to_topic(client, peer, topic_root_message_id, args.text)

        payload: dict[str, Any] = {
            "ok": True,
            "sent": message_to_dict(sent),
            "topic_id": topic_id,
            "topic_root_message_id": topic_root_message_id,
            "topic_title": topic_title,
        }

        if args.expect_from:
            reply = await wait_for_reply(
                client,
                peer,
                topic_id=topic_id,
                sent_id=sent.id,
                expect_from=args.expect_from,
                timeout_sec=args.timeout_sec,
                poll_sec=args.poll_sec,
            )
            if reply is None:
                payload["ok"] = False
                payload["error"] = f"No reply from {args.expect_from!r} within {args.timeout_sec}s"
                emit(payload, args.json)
                return 1
            payload["reply"] = message_to_dict(reply)

        emit(payload, args.json)
        return 0
    finally:
        await client.disconnect()


def main() -> int:
    try:
        return asyncio.run(async_main())
    except KeyboardInterrupt:
        return 130
    except Exception as exc:  # pragma: no cover - CLI surface
        print(
            json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, indent=2),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
