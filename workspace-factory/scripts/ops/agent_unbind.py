#!/usr/bin/env python3
"""Remove a Telegram binding for an agent."""
import argparse
import json
import os
import shutil
import sys


def main():
    p = argparse.ArgumentParser(description="Remove agent Telegram binding")
    p.add_argument("--agent", required=True)
    p.add_argument("--chat-id", default="", help="Specific chat to unbind (optional, removes all if empty)")
    args = p.parse_args()

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config_path = f"{home}/openclaw.json"
    d = json.load(open(config_path))

    shutil.copy2(config_path, f"{config_path}.bak")

    before = len(d.get("bindings", []))
    if args.chat_id:
        d["bindings"] = [b for b in d.get("bindings", [])
                         if not (b.get("agentId") == args.agent and args.chat_id in b.get("match", {}).get("peer", {}).get("id", ""))]
    else:
        d["bindings"] = [b for b in d.get("bindings", []) if b.get("agentId") != args.agent]
    after = len(d["bindings"])

    json.dump(d, open(config_path, "w"), indent=2, ensure_ascii=False)

    print(json.dumps({
        "ok": True,
        "action": "agent_unbind",
        "agent": args.agent,
        "removed": before - after,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
