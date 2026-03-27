#!/usr/bin/env python3
"""Change model for an agent."""
import argparse
import json
import os
import shutil
import sys


def main():
    p = argparse.ArgumentParser(description="Set agent model")
    p.add_argument("--agent", required=True)
    p.add_argument("--model", required=True, help="Model ID (e.g. anthropic/claude-sonnet-4-6)")
    p.add_argument("--fallback", default="", help="Fallback model")
    args = p.parse_args()

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config_path = f"{home}/openclaw.json"
    d = json.load(open(config_path))

    found = False
    for a in d.get("agents", {}).get("list", []):
        if a.get("id") == args.agent:
            shutil.copy2(config_path, f"{config_path}.bak")
            a["model"] = {"primary": args.model}
            if args.fallback:
                a["model"]["fallbacks"] = [args.fallback]
            found = True
            break

    if not found:
        print(json.dumps({"ok": False, "error": f"Agent '{args.agent}' not found"}))
        return 1

    json.dump(d, open(config_path, "w"), indent=2, ensure_ascii=False)
    print(json.dumps({"ok": True, "action": "agent_set_model", "agent": args.agent, "model": args.model}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
