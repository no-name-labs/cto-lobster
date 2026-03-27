#!/usr/bin/env python3
"""Enable or disable an OpenClaw plugin."""
import argparse
import json
import os
import shutil
import sys


def main():
    p = argparse.ArgumentParser(description="Enable or disable a plugin")
    p.add_argument("--plugin", required=True, help="Plugin ID (e.g. telegram, lobster)")
    p.add_argument("--enable", action="store_true")
    p.add_argument("--disable", action="store_true")
    args = p.parse_args()

    if not args.enable and not args.disable:
        print(json.dumps({"ok": False, "error": "Specify --enable or --disable"}))
        return 1

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config_path = f"{home}/openclaw.json"
    d = json.load(open(config_path))

    shutil.copy2(config_path, f"{config_path}.bak")

    plugins = d.setdefault("plugins", {})
    allow = plugins.setdefault("allow", [])
    entries = plugins.setdefault("entries", {})

    if args.enable:
        if args.plugin not in allow:
            allow.append(args.plugin)
        entries[args.plugin] = {"enabled": True}
        action = "enabled"
    else:
        if args.plugin in allow:
            allow.remove(args.plugin)
        if args.plugin in entries:
            entries[args.plugin]["enabled"] = False
        action = "disabled"

    json.dump(d, open(config_path, "w"), indent=2, ensure_ascii=False)
    print(json.dumps({"ok": True, "action": f"plugin_{action}", "plugin": args.plugin, "note": "Gateway restart needed"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
