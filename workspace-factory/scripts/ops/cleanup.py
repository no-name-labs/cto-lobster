#!/usr/bin/env python3
"""Cleanup orphaned state: stale bindings, orphan crons, stale locks/progress.

Safe to run anytime. Reports what it finds and fixes.
Usage: python3 cleanup.py [--dry-run]
"""
import json
import os
import pathlib
import subprocess
import sys
import time


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
    dry_run = "--dry-run" in sys.argv
    home = os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw"))
    config_path = pathlib.Path(f"{home}/openclaw.json")
    fixes = []

    if not config_path.exists():
        print(json.dumps({"ok": False, "error": "openclaw.json not found"}))
        return 1

    d = json.loads(config_path.read_text())
    agents = {a["id"] for a in d.get("agents", {}).get("list", []) if isinstance(a, dict)}
    bindings = d.get("bindings", [])
    changed = False

    # 1a. Orphan bindings — binding for agent that doesn't exist
    orphan_bindings = [b for b in bindings if b.get("agentId") not in agents]
    if orphan_bindings:
        for ob in orphan_bindings:
            fixes.append(f"remove orphan binding: {ob.get('agentId')} -> {ob.get('match', {}).get('peer', {}).get('id', '?')}")
        if not dry_run:
            d["bindings"] = [b for b in bindings if b.get("agentId") in agents]
            bindings = d["bindings"]
            changed = True

    # 1b. CTO-topic hijack — non-CTO agents bound to CTO's topic
    cto_peer = ""
    # Try resolve_cto_topic.sh first
    try:
        resolve_script = pathlib.Path(f"{home}/workspace-factory/scripts/resolve_cto_topic.sh")
        if resolve_script.exists():
            result = subprocess.run(
                ["bash", str(resolve_script), home],
                capture_output=True, text=True, timeout=5
            )
            cto_peer = result.stdout.strip()
    except Exception:
        pass
    # Fallback: check CTO binding directly
    if not cto_peer:
        for b in d.get("bindings", []):
            if b.get("agentId") == "cto-factory":
                cto_peer = b.get("match", {}).get("peer", {}).get("id", "")
                break
    if cto_peer:
        bad_bindings = [
            b for b in d.get("bindings", [])
            if b.get("agentId") != "cto-factory"
            and b.get("match", {}).get("peer", {}).get("id") == cto_peer
        ]
        if bad_bindings:
            for bb in bad_bindings:
                fixes.append(f"remove CTO-topic hijack: {bb.get('agentId')} bound to CTO peer {cto_peer}")
            if not dry_run:
                d["bindings"] = [b for b in d["bindings"] if b not in bad_bindings]
                changed = True

    # 2. Orphan crons — cron for agent that doesn't exist
    try:
        stdout, _, rc = run_openclaw("cron", "list", "--json")
        if rc == 0:
            # Find JSON in output (skip non-JSON preamble lines)
            for line in stdout.splitlines():
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    cron_data = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for job in cron_data.get("jobs", []):
                    agent_id = job.get("agentId", "")
                    if agent_id and agent_id not in agents:
                        fixes.append(f"orphan cron: {job.get('name', '?')} agent={agent_id} id={job.get('id', '?')}")
                        if not dry_run:
                            run_openclaw("cron", "delete", job["id"])
                break
    except Exception as e:
        fixes.append(f"cron check error: {e}")

    # 3. Stale lock
    lock_path = pathlib.Path(f"{home}/workspace-factory/.cto-brain/runtime/build.lock")
    if lock_path.exists():
        lock_age = time.time() - lock_path.stat().st_mtime
        # Check if processes alive
        try:
            ps = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=5).stdout
            alive = "lobster" in ps or "code_agent_exec" in ps
        except Exception:
            alive = False

        if lock_age > 1800 and not alive:
            fixes.append(f"stale lock (age: {int(lock_age)}s, no alive processes)")
            if not dry_run:
                lock_path.unlink(missing_ok=True)
        elif not alive and lock_age > 300:
            fixes.append(f"likely stale lock (age: {int(lock_age)}s, no processes)")
            if not dry_run:
                lock_path.unlink(missing_ok=True)

    # 4. Stale progress — fix inconsistent state
    progress_path = pathlib.Path(f"{home}/workspace-factory/.cto-brain/runtime/build_progress.json")
    if progress_path.exists():
        try:
            pdata = json.loads(progress_path.read_text())
            status = pdata.get("status", "")
            step = pdata.get("current_step", "")

            # 4a. status=running but no processes alive
            if status == "running":
                try:
                    ps = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=5).stdout
                    alive = "lobster" in ps or "code_agent_exec" in ps
                except Exception:
                    alive = False
                if not alive:
                    fixes.append(f"stale progress: {pdata.get('agent_id', '?')} claimed running but no processes")
                    if not dry_run:
                        pdata["status"] = "failed"
                        pdata["current_step"] = "failed"
                        pdata["error"] = "stale: cleaned by cleanup.py"
                        progress_path.write_text(json.dumps(pdata, indent=2))

            # 4b. status=completed/failed but current_step still "launching"
            # This is inconsistent — fix current_step to match status
            elif status in ("completed", "failed") and step == "launching":
                target_step = "done" if status == "completed" else "failed"
                fixes.append(f"fix inconsistent progress: status={status} but current_step=launching -> {target_step}")
                if not dry_run:
                    pdata["current_step"] = target_step
                    progress_path.write_text(json.dumps(pdata, indent=2))
        except Exception:
            pass

    # 5. Stale workspaces — workspace dir exists but agent not registered
    for ws in pathlib.Path(home).glob("workspace-*"):
        if ws.name == "workspace-factory":
            continue
        agent_id = ws.name.replace("workspace-", "")
        if agent_id not in agents:
            fixes.append(f"orphan workspace: {ws.name} (agent not registered)")
            # Don't auto-delete workspaces — just report

    # Save config changes
    if changed and not dry_run:
        config_path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")

    result = {
        "ok": True,
        "dry_run": dry_run,
        "fixes": fixes,
        "fix_count": len(fixes),
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
