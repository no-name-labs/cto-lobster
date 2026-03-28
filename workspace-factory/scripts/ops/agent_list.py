#!/usr/bin/env python3
"""List registered agents. Read-only."""
import json
import os
import sys


def main():
    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config_path = f"{home}/openclaw.json"

    try:
        d = json.load(open(config_path))
    except Exception as e:
        print(json.dumps({"ok": False, "error": f"Cannot read config: {e}"}))
        return 1

    agents = []
    for a in d.get("agents", {}).get("list", []):
        agents.append({
            "id": a.get("id"),
            "name": a.get("name", ""),
            "model": (a.get("model", {}).get("primary", "default") if isinstance(a.get("model"), dict) else str(a.get("model", "default"))),
            "workspace": a.get("workspace", ""),
            "default": a.get("default", False),
        })

    bindings = []
    for b in d.get("bindings", []):
        bindings.append({
            "agent": b.get("agentId"),
            "channel": b.get("match", {}).get("channel", ""),
            "peer": b.get("match", {}).get("peer", {}).get("id", ""),
        })

    print(json.dumps({
        "ok": True,
        "action": "agent_list",
        "count": len(agents),
        "agents": agents,
        "bindings": bindings,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
