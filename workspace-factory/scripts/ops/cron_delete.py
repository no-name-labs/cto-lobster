#!/usr/bin/env python3
"""Delete a cron job by ID. Validates existence before deleting."""
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
    p = argparse.ArgumentParser(description="Delete an OpenClaw cron job")
    p.add_argument("--id", required=True, help="Cron job ID to delete")
    args = p.parse_args()

    # Verify job exists
    stdout, _, _ = run_openclaw("cron", "list", "--json")
    try:
        jobs = json.loads(stdout).get("jobs", [])
        found = any(j.get("id") == args.id for j in jobs)
    except (json.JSONDecodeError, KeyError):
        found = False

    if not found:
        print(json.dumps({"ok": False, "error": f"Cron job '{args.id}' not found"}))
        return 1

    # Delete
    stdout, stderr, code = run_openclaw("cron", "delete", args.id, "--json")
    if code != 0:
        print(json.dumps({"ok": False, "error": stderr or stdout}))
        return 1

    print(json.dumps({"ok": True, "action": "cron_delete", "deleted_id": args.id}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
