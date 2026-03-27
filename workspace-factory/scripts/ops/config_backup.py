#!/usr/bin/env python3
"""Backup or restore openclaw.json."""
import argparse
import json
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description="Backup or restore openclaw.json")
    p.add_argument("--backup", action="store_true", help="Create a backup")
    p.add_argument("--restore", default="", help="Restore from backup file path")
    p.add_argument("--list", action="store_true", help="List available backups")
    args = p.parse_args()

    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config_path = Path(f"{home}/openclaw.json")
    backup_dir = Path(f"{home}/backups")

    if args.list:
        backups = []
        if backup_dir.exists():
            for f in sorted(backup_dir.glob("openclaw.json.*")):
                backups.append({"file": str(f), "size": f.stat().st_size, "modified": f.stat().st_mtime})
        # Also check .bak files
        for f in sorted(config_path.parent.glob("openclaw.json.bak*")):
            backups.append({"file": str(f), "size": f.stat().st_size, "modified": f.stat().st_mtime})
        print(json.dumps({"ok": True, "action": "config_list_backups", "count": len(backups), "backups": backups}))
        return 0

    if args.backup:
        backup_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(__import__("datetime").timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dest = backup_dir / f"openclaw.json.{ts}"
        shutil.copy2(config_path, dest)
        print(json.dumps({"ok": True, "action": "config_backup", "file": str(dest)}))
        return 0

    if args.restore:
        src = Path(args.restore)
        if not src.exists():
            print(json.dumps({"ok": False, "error": f"Backup file not found: {args.restore}"}))
            return 1
        # Validate it's valid JSON
        try:
            json.loads(src.read_text())
        except json.JSONDecodeError:
            print(json.dumps({"ok": False, "error": "Backup file is not valid JSON"}))
            return 1
        # Backup current before restoring
        backup_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(__import__("datetime").timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        shutil.copy2(config_path, backup_dir / f"openclaw.json.pre-restore.{ts}")
        shutil.copy2(src, config_path)
        print(json.dumps({"ok": True, "action": "config_restore", "from": str(src), "note": "Gateway restart needed"}))
        return 0

    print(json.dumps({"ok": False, "error": "Specify --backup, --restore <path>, or --list"}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
