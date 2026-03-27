#!/usr/bin/env python3
"""Enable or disable a cron job."""
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
    r = subprocess.run(["openclaw"] + list(args), capture_output=True, text=True, timeout=timeout, env=env)
    return r.stdout.strip(), r.stderr.strip(), r.returncode


def main():
    p = argparse.ArgumentParser(description="Enable or disable a cron job")
    p.add_argument("--id", required=True, help="Cron job ID")
    p.add_argument("--enable", action="store_true")
    p.add_argument("--disable", action="store_true")
    args = p.parse_args()

    if not args.enable and not args.disable:
        print(json.dumps({"ok": False, "error": "Specify --enable or --disable"}))
        return 1

    action = "enable" if args.enable else "disable"
    stdout, stderr, code = run_openclaw("cron", action, args.id)

    if code != 0:
        print(json.dumps({"ok": False, "error": stderr or stdout}))
        return 1

    print(json.dumps({"ok": True, "action": f"cron_{action}", "id": args.id}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
