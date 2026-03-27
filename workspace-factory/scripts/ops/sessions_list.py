#!/usr/bin/env python3
"""List agent sessions. Read-only."""
import argparse
import json
import os
import subprocess
import sys


def main():
    p = argparse.ArgumentParser(description="List agent sessions")
    p.add_argument("--agent", default="", help="Filter by agent ID")
    p.add_argument("--active", type=int, default=60, help="Only sessions active in last N minutes")
    args = p.parse_args()

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    env = os.environ.copy()
    env["OPENCLAW_STATE_DIR"] = home
    env["OPENCLAW_CONFIG_PATH"] = f"{home}/openclaw.json"

    cmd = ["openclaw", "sessions", "--json"]
    if args.agent:
        cmd += ["--agent", args.agent]
    if args.active:
        cmd += ["--active", str(args.active)]

    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15, env=env)
        for line in r.stdout.splitlines():
            if line.strip().startswith("{"):
                data = json.loads(line)
                sessions = data.get("sessions", [])
                print(json.dumps({
                    "ok": True,
                    "action": "sessions_list",
                    "count": len(sessions),
                    "sessions": [{"agent": s.get("agentId"), "model": s.get("model"), "status": s.get("status"), "age_seconds": s.get("ageMs", 0) // 1000} for s in sessions],
                }))
                return 0
        print(json.dumps({"ok": False, "error": "No JSON output"}))
        return 1
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
