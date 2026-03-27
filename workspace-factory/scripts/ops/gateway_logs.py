#!/usr/bin/env python3
"""Show recent gateway logs. Read-only."""
import argparse
import json
import os
import sys
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description="Show gateway logs")
    p.add_argument("--lines", type=int, default=50, help="Number of lines to show")
    p.add_argument("--search", default="", help="Filter lines containing this text")
    args = p.parse_args()

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))

    # Try multiple log locations
    candidates = [
        Path(home) / "logs" / "gateway.log",
        Path(home) / "logs" / "gateway-run.log",
        Path("/tmp/openclaw") / f"openclaw-{__import__('datetime').date.today()}.log",
    ]

    log_path = None
    for c in candidates:
        if c.exists():
            log_path = c
            break

    if not log_path:
        print(json.dumps({"ok": False, "error": "No gateway log found", "searched": [str(c) for c in candidates]}))
        return 1

    lines = log_path.read_text().splitlines()
    if args.search:
        lines = [l for l in lines if args.search.lower() in l.lower()]

    tail = lines[-args.lines:]

    print(json.dumps({
        "ok": True,
        "action": "gateway_logs",
        "file": str(log_path),
        "total_lines": len(lines),
        "showing": len(tail),
        "lines": tail,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
