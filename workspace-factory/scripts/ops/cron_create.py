#!/usr/bin/env python3
"""Create a cron job for an agent. Validates, creates, verifies."""
import argparse
import json
import os
import subprocess
import sys


def run_openclaw(*args, timeout=30):
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
    p = argparse.ArgumentParser(description="Create an OpenClaw cron job")
    p.add_argument("--agent", required=True, help="Agent ID")
    p.add_argument("--schedule", required=True, help="Cron expression (e.g. '0 9 * * *')")
    p.add_argument("--tz", default="UTC", help="Timezone (default: UTC)")
    p.add_argument("--message", default="/run_now", help="Agent message payload")
    p.add_argument("--name", default="", help="Cron job name")
    p.add_argument("--exact", action="store_true", help="Disable staggering")
    args = p.parse_args()

    name = args.name or f"{args.agent}-daily"

    # Validate agent exists
    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config = json.load(open(f"{home}/openclaw.json"))
    agent_ids = [a["id"] for a in config.get("agents", {}).get("list", [])]
    if args.agent not in agent_ids:
        print(json.dumps({"ok": False, "error": f"Agent '{args.agent}' not found. Available: {agent_ids}"}))
        return 1

    # Create cron
    cmd = [
        "cron", "create",
        "--agent", args.agent,
        "--cron", args.schedule,
        "--tz", args.tz,
        "--name", name,
        "--message", args.message,
        "--exact",
        "--json",
    ]
    stdout, stderr, code = run_openclaw(*cmd)

    if code != 0:
        print(json.dumps({"ok": False, "error": stderr or stdout, "exit_code": code}))
        return 1

    # Parse result
    try:
        result = json.loads(stdout)
        cron_id = result.get("id", "unknown")
    except (json.JSONDecodeError, KeyError):
        cron_id = "unknown"

    # Verify it was created
    verify_stdout, _, _ = run_openclaw("cron", "list", "--json")
    try:
        cron_list = json.loads(verify_stdout)
        found = any(j.get("id") == cron_id or j.get("name") == name for j in cron_list.get("jobs", []))
    except (json.JSONDecodeError, KeyError):
        found = False

    print(json.dumps({
        "ok": True,
        "action": "cron_create",
        "cron_id": cron_id,
        "agent": args.agent,
        "schedule": args.schedule,
        "tz": args.tz,
        "name": name,
        "verified": found,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
