#!/usr/bin/env python3
"""Validate cron delivery targets have :topic: suffix. Delete bad ones.

Usage: validate_cron_delivery.py <agent_id>
Returns JSON with fixes applied.
"""
import json
import os
import subprocess
import sys


def run_openclaw(*args, timeout=15):
    env = os.environ.copy()
    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    env["OPENCLAW_STATE_DIR"] = home
    env["OPENCLAW_CONFIG_PATH"] = f"{home}/openclaw.json"
    env_file = f"{home}/.env"
    if os.path.exists(env_file):
        for line in open(env_file):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    result = subprocess.run(
        ["openclaw"] + list(args),
        capture_output=True, text=True, timeout=timeout, env=env
    )
    return result.stdout.strip(), result.stderr.strip(), result.returncode


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": True, "checked": False}))
        return 0

    agent_id = sys.argv[1]
    stdout, _, rc = run_openclaw("cron", "list", "--json")
    if rc != 0:
        print(json.dumps({"ok": True, "checked": False, "error": "cron list failed"}))
        return 0

    fixes = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        for job in data.get("jobs", []):
            if job.get("agentId") != agent_id:
                continue
            to = job.get("delivery", {}).get("to", "")
            if to and ":topic:" not in to:
                fixes.append({
                    "name": job.get("name", "?"),
                    "id": job["id"],
                    "bad_target": to,
                    "action": "deleted"
                })
                run_openclaw("cron", "delete", job["id"])
        break

    print(json.dumps({"ok": True, "agent_id": agent_id, "fixes": fixes}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
