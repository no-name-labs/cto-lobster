#!/usr/bin/env python3
"""Set an environment variable in .env file."""
import argparse
import json
import os
import sys


def main():
    p = argparse.ArgumentParser(description="Set env var in .env")
    p.add_argument("--key", required=True, help="Variable name")
    p.add_argument("--value", required=True, help="Variable value")
    args = p.parse_args()

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    env_file = f"{home}/.env"

    # Read existing
    lines = []
    if os.path.exists(env_file):
        lines = open(env_file).read().splitlines()

    # Update or append
    updated = False
    for i, line in enumerate(lines):
        if line.startswith(f"{args.key}="):
            lines[i] = f"{args.key}={args.value}"
            updated = True
            break

    if not updated:
        lines.append(f"{args.key}={args.value}")

    open(env_file, "w").write("\n".join(lines) + "\n")
    os.chmod(env_file, 0o600)

    print(json.dumps({"ok": True, "action": "env_set", "key": args.key, "note": "Gateway restart needed for changes to take effect"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
