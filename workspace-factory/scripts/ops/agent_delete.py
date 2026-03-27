#!/usr/bin/env python3
"""Remove an agent from openclaw.json. Backs up before modifying."""
import argparse
import json
import os
import shutil
import sys


def main():
    p = argparse.ArgumentParser(description="Remove agent from OpenClaw config")
    p.add_argument("--agent", required=True, help="Agent ID to remove")
    p.add_argument("--delete-workspace", action="store_true", help="Also delete workspace directory")
    args = p.parse_args()

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config_path = f"{home}/openclaw.json"

    d = json.load(open(config_path))
    agents = d.get("agents", {}).get("list", [])
    found = any(a.get("id") == args.agent for a in agents)

    if not found:
        print(json.dumps({"ok": False, "error": f"Agent '{args.agent}' not found"}))
        return 1

    # Backup
    shutil.copy2(config_path, f"{config_path}.bak")

    # Remove agent
    workspace = None
    for a in agents:
        if a.get("id") == args.agent:
            workspace = a.get("workspace", "")
    d["agents"]["list"] = [a for a in agents if a.get("id") != args.agent]
    d["bindings"] = [b for b in d.get("bindings", []) if b.get("agentId") != args.agent]

    json.dump(d, open(config_path, "w"), indent=2, ensure_ascii=False)

    # Delete workspace if requested
    ws_deleted = False
    if args.delete_workspace and workspace and os.path.isdir(workspace):
        shutil.rmtree(workspace)
        ws_deleted = True

    print(json.dumps({
        "ok": True,
        "action": "agent_delete",
        "agent": args.agent,
        "workspace_deleted": ws_deleted,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
