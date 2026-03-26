#!/usr/bin/env python3
"""Bind an agent to a Telegram topic. Creates binding in openclaw.json."""
import argparse
import json
import os
import shutil
import sys


def main():
    p = argparse.ArgumentParser(description="Bind agent to Telegram topic")
    p.add_argument("--agent", required=True)
    p.add_argument("--chat-id", required=True, help="Telegram group ID")
    p.add_argument("--topic-id", default="", help="Telegram topic ID")
    args = p.parse_args()

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config_path = f"{home}/openclaw.json"

    try:
        d = json.load(open(config_path))
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"Cannot read config: {e}"}))
        return 1

    # Verify agent exists
    agent_ids = [a["id"] for a in d.get("agents", {}).get("list", [])]
    if args.agent not in agent_ids:
        print(json.dumps({"ok": False, "error": f"Agent '{args.agent}' not found"}))
        return 1

    # Build peer ID
    peer_id = f"{args.chat_id}:topic:{args.topic_id}" if args.topic_id else args.chat_id

    # Check if binding exists
    bindings = d.setdefault("bindings", [])
    for b in bindings:
        if b.get("agentId") == args.agent and b.get("match", {}).get("peer", {}).get("id") == peer_id:
            print(json.dumps({"ok": True, "action": "agent_bind", "already_exists": True, "peer": peer_id}))
            return 0

    # Backup
    shutil.copy2(config_path, f"{config_path}.bak")

    # Add binding
    bindings.append({
        "agentId": args.agent,
        "match": {
            "channel": "telegram",
            "accountId": "default",
            "peer": {"kind": "group", "id": peer_id}
        }
    })

    json.dump(d, open(config_path, "w"), indent=2, ensure_ascii=False)

    # Verify
    d2 = json.load(open(config_path))
    found = any(
        b.get("agentId") == args.agent and b.get("match", {}).get("peer", {}).get("id") == peer_id
        for b in d2.get("bindings", [])
    )

    print(json.dumps({
        "ok": found,
        "action": "agent_bind",
        "agent": args.agent,
        "peer": peer_id,
        "verified": found,
    }))
    return 0 if found else 1


if __name__ == "__main__":
    sys.exit(main())
