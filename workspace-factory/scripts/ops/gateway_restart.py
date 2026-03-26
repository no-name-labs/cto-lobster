#!/usr/bin/env python3
"""Restart OpenClaw gateway safely. macOS/Linux aware, retries, health check."""
import json
import os
import platform
import subprocess
import sys
import time


def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, shell=isinstance(cmd, str))
        return r.stdout.strip(), r.stderr.strip(), r.returncode
    except subprocess.TimeoutExpired:
        return "", "timeout", 124


def main():
    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    is_mac = platform.system() == "Darwin"

    # Stop
    if is_mac:
        uid = os.getuid()
        run(f"launchctl bootout gui/{uid}/ai.openclaw.gateway")
    else:
        run("openclaw gateway stop")
    time.sleep(2)

    # Start
    if is_mac:
        uid = os.getuid()
        plist = os.path.expanduser("~/Library/LaunchAgents/ai.openclaw.gateway.plist")
        out, err, code = run(f"launchctl bootstrap gui/{uid} {plist}")
        if code != 0:
            run("openclaw gateway install")
    else:
        out, err, code = run("openclaw gateway start")
        if code != 0:
            # Fallback: foreground
            os.makedirs(f"{home}/logs", exist_ok=True)
            subprocess.Popen(
                f"cd {home} && OPENCLAW_STATE_DIR={home} OPENCLAW_CONFIG_PATH={home}/openclaw.json "
                f"nohup openclaw gateway run --port {os.environ.get('OPENCLAW_PORT', '18789')} "
                f"> {home}/logs/gateway.log 2>&1 &",
                shell=True
            )

    # Health check with retries
    time.sleep(5)
    for attempt in range(1, 4):
        out, _, _ = run("openclaw gateway status")
        if "probe: ok" in out:
            print(json.dumps({"ok": True, "action": "gateway_restart", "attempts": attempt}))
            return 0
        time.sleep(3)

    print(json.dumps({"ok": False, "action": "gateway_restart", "error": "Health check failed after 3 retries"}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
