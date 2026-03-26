#!/usr/bin/env python3
"""Validate OpenClaw config. Read-only."""
import json
import os
import subprocess
import sys


def main():
    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    env = os.environ.copy()
    env["OPENCLAW_STATE_DIR"] = home
    env["OPENCLAW_CONFIG_PATH"] = f"{home}/openclaw.json"
    env_file = f"{home}/.env"
    if os.path.exists(env_file):
        for line in open(env_file):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v

    try:
        r = subprocess.run(
            ["openclaw", "config", "validate", "--json"],
            capture_output=True, text=True, timeout=15, env=env
        )
        # Find JSON in output
        for line in r.stdout.splitlines():
            line = line.strip()
            if line.startswith("{"):
                result = json.loads(line)
                valid = result.get("valid", False)
                print(json.dumps({"ok": True, "valid": valid, "details": result}))
                return 0 if valid else 1
        print(json.dumps({"ok": False, "error": "No JSON output from config validate"}))
        return 1
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
