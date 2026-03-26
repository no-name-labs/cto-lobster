#!/usr/bin/env python3
"""Check gateway status. Read-only."""
import json
import os
import subprocess
import sys


def main():
    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    env = os.environ.copy()
    env["OPENCLAW_STATE_DIR"] = home
    env["OPENCLAW_CONFIG_PATH"] = f"{home}/openclaw.json"

    try:
        r = subprocess.run(["openclaw", "gateway", "status"], capture_output=True, text=True, timeout=15, env=env)
        alive = "probe: ok" in r.stdout
        print(json.dumps({"ok": True, "alive": alive, "output": r.stdout[:500]}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
