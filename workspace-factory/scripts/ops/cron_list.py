#!/usr/bin/env python3
"""List cron jobs. Read-only, safe to run anytime."""
import argparse
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
    p = argparse.ArgumentParser(description="List OpenClaw cron jobs")
    p.add_argument("--agent", default="", help="Filter by agent ID")
    args = p.parse_args()

    cmd = ["cron", "list", "--json"]
    stdout, stderr, code = run_openclaw(*cmd)

    if code != 0:
        print(json.dumps({"ok": False, "error": stderr or stdout}))
        return 1

    try:
        data = json.loads(stdout)
        jobs = data.get("jobs", [])
    except json.JSONDecodeError:
        print(json.dumps({"ok": False, "error": "Failed to parse cron list output"}))
        return 1

    if args.agent:
        jobs = [j for j in jobs if j.get("agentId", "") == args.agent]

    print(json.dumps({
        "ok": True,
        "action": "cron_list",
        "count": len(jobs),
        "jobs": [{"id": j.get("id"), "name": j.get("name"), "agent": j.get("agentId"), "schedule": j.get("schedule", {}).get("raw", ""), "enabled": j.get("enabled", True)} for j in jobs],
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
