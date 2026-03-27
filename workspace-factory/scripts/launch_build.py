#!/usr/bin/env python3
"""
Launch lobster pipeline with automatic progress reporting to Telegram.

CTO calls this script once. It:
1. Launches lobster in background
2. Detects which step is running (research, T1-T6, smoke, verify, etc.)
3. Sends Telegram progress updates at each stage change
4. Sends final result (success / failure / approval needed)

CTO does NOT need to stay alive during the build.

Usage:
  python3 launch_build.py --action create --agent-id my-agent --prompts-dir /tmp/my-agent-build
  python3 launch_build.py --action edit --agent-id my-agent --prompts-dir /tmp/my-agent-edit
  python3 launch_build.py --action diagnostic
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# Step labels for Telegram reporting
STEP_LABELS = {
    "RESEARCH.txt": "🔬 Research",
    "T1.txt": "🏗️ T1: Scaffold",
    "T2.txt": "⚙️ T2: Core Logic",
    "T3.txt": "🧠 T3: Processing",
    "T4.txt": "📬 T4: Delivery",
    "T5.txt": "🔗 T5: Integration",
    "T6.txt": "🎯 T6: Advanced",
    "T7.txt": "🔩 T7: Extra",
    "T8.txt": "🔩 T8: Extra",
    "SMOKE.txt": "🧪 Smoke Test",
    "VERIFY.txt": "📝 Verification",
    "FIX.txt": "🔧 Fix",
}

# Progress file — CTO reads this to restore context after turn ends
# Written to .cto-brain/runtime/build_progress.json
PROGRESS_SCHEMA = {
    "agent_id": "",
    "action": "",
    "status": "running",       # running | completed | failed | approval_needed
    "current_step": "",
    "completed_steps": [],
    "elapsed_seconds": 0,
    "workspace_stats": {},
    "error": "",
    "resume_token": "",
    "started_at": "",
    "updated_at": "",
}


def write_progress(root: str, progress: dict):
    """Write progress file so CTO can read it to restore context."""
    progress["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    pdir = Path(root) / "workspace-factory" / ".cto-brain" / "runtime"
    pdir.mkdir(parents=True, exist_ok=True)
    pfile = pdir / "build_progress.json"
    try:
        pfile.write_text(json.dumps(progress, indent=2))
    except Exception:
        pass


def sanitize_prompt_paths(prompts_dir: str, root: str, workspace: str, agent_id: str = ""):
    """Replace unresolved variables and fix wrong workspace paths in prompt files.
    CTO often writes OPENCLAW_ROOT variable refs, ~/.openclaw, or agents/<id> instead of workspace-<id>.
    """
    home = str(Path.home())
    pd = Path(prompts_dir)
    dollar = "$"
    replacements = [
        (dollar + "OPENCLAW_ROOT", root),
        (dollar + "{OPENCLAW_ROOT}", root),
        ("~/.openclaw", root),
        (dollar + "HOME/.openclaw", root),
        (dollar + "{HOME}/.openclaw", root),
        (dollar + "WORKSPACE", workspace),
        (dollar + "{WORKSPACE}", workspace),
    ]
    # Fix ALL known wrong workspace paths → correct workspace-<id>
    if agent_id and workspace:
        wrong_paths = [
            f"{root}/agents/{agent_id}",
            f"{root}/agents/{agent_id}/agent",
            f"{root}/workspaces/{agent_id}",
            f"{root}/workspace/{agent_id}",
        ]
        for wrong in wrong_paths:
            replacements.append((wrong, workspace))
    for f in pd.glob("*.txt"):
        content = f.read_text()
        original = content
        for old, new in replacements:
            content = content.replace(old, new)
        # Also replace bare ~ at start of paths (~/anything)
        content = re.sub(r'(?<!\w)~/', f'{home}/', content)
        # Catch-all: any path with root + <something>/<agent_id> that isn't workspace-<id>
        if agent_id and workspace:
            import re as _re
            pattern = _re.escape(root) + r'/[a-zA-Z]+/' + _re.escape(agent_id)
            for match in _re.findall(pattern, content):
                if match != workspace:
                    content = content.replace(match, workspace)
        if content != original:
            f.write_text(content)
            log(f"  Fixed paths in {f.name}")


def find_openclaw_root() -> str:
    env = os.environ.get("OPENCLAW_ROOT", "").strip()
    if env and Path(env).is_dir():
        return env
    for candidate in [Path.home() / ".openclaw", Path("/home/ubuntu/.openclaw")]:
        if (candidate / "openclaw.json").exists():
            return str(candidate)
    raise SystemExit("Cannot find OPENCLAW_ROOT.")


def notify(chat_id: str, topic_id: str, message: str):
    """Send notification to CTO's Telegram topic via openclaw message send."""
    if not chat_id:
        return
    target = f"{chat_id}:topic:{topic_id}" if topic_id else chat_id
    try:
        subprocess.run(
            ["openclaw", "message", "send", "--channel", "telegram",
             "--target", target, "-m", message, "--json"],
            capture_output=True, text=True, timeout=30,
        )
    except Exception:
        pass


def detect_active_step(prompts_dir: str) -> str | None:
    """Check which prompt file is currently being processed by code agent.
    Uses two methods: ps aux for active process, and context dir for completed steps."""
    # Method 1: Check ps aux for running code_agent_exec
    try:
        result = subprocess.run(
            ["ps", "aux"], capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            if "code_agent_exec" in line or "codex_guarded_exec" in line:
                m = re.search(r"--prompt-file\s+(\S+)", line)
                if m:
                    name = Path(m.group(1)).name
                    if "$" not in name and name.endswith(".txt"):
                        return name
            if "claude" in line and "--print" in line:
                m = re.search(r"--prompt-file\s+(\S+)", line)
                if m:
                    name = Path(m.group(1)).name
                    if "$" not in name and name.endswith(".txt"):
                        return name
                m = re.search(r"(/\S+?/([A-Z0-9_]+\.txt))", line)
                if m and "$" not in m.group(2):
                    return m.group(2)
    except Exception:
        pass

    # Method 2 removed — st_atime is unreliable (OS prefetch, antivirus scanning)
    # causes false "T4 started" detections. Only ps-based detection is trustworthy.
    return None


def detect_step_from_reports(prompts_dir: str) -> tuple[str | None, int]:
    """Check which steps have completed based on report files."""
    pd = Path(prompts_dir)
    reports = sorted(pd.glob("*-report*"))
    completed = len(reports)
    last = reports[-1].stem if reports else None
    return last, completed


def count_workspace_files(workspace: str) -> dict:
    """Count files in workspace for progress reporting."""
    ws = Path(workspace)
    if not ws.exists():
        return {"exists": False}
    py_files = len(list(ws.rglob("*.py")))
    test_dir = ws / "tests"
    test_files = len(list(test_dir.rglob("*.py"))) if test_dir.exists() else 0
    return {"exists": True, "py_files": py_files, "test_files": test_files}


def main():
    p = argparse.ArgumentParser(description="Launch lobster pipeline with progress reporting")
    p.add_argument("--action", choices=["create", "edit", "diagnostic", "install"], required=True)
    p.add_argument("--agent-id", help="Agent ID (required for create/edit/install)")
    p.add_argument("--prompts-dir", help="Directory with prompt files")
    p.add_argument("--repo-url", default="", help="GitHub repo URL (required for install)")
    p.add_argument("--chat-id", default="", help="Telegram chat ID for AGENT binding (where agent will live)")
    p.add_argument("--topic-id", default="", help="Telegram topic ID for AGENT binding")
    # --notify-chat-id/--notify-topic-id kept for backward compat but unused
    # Notifications handled by lobster steps + build_monitor.sh
    p.add_argument("--notify-chat-id", default="", help="(deprecated) notifications handled by lobster")
    p.add_argument("--notify-topic-id", default="", help="(deprecated) notifications handled by lobster")
    p.add_argument("--test-cmd", default="python3 -m pytest -q", help="Test runner command")
    p.add_argument("--timeout", type=int, default=7200, help="Max runtime in seconds (default: 2h)")
    p.add_argument("--_background", action="store_true", help=argparse.SUPPRESS)  # internal: run pipeline directly
    args = p.parse_args()

    root = find_openclaw_root()
    factory = f"{root}/workspace-factory"

    # If called with --_background, skip spawn and run pipeline directly
    is_background = args._background

    # Auto-resolve CTO notification target from openclaw.json binding
    notify_chat = ""
    notify_topic = ""
    try:
        config = json.loads(Path(f"{root}/openclaw.json").read_text())
        for b in config.get("bindings", []):
            if b.get("agentId") == "cto-factory":
                peer = b.get("match", {}).get("peer", {}).get("id", "")
                if ":topic:" in peer:
                    parts = peer.split(":topic:")
                    notify_chat = parts[0]
                    notify_topic = parts[1]
                else:
                    notify_chat = peer
                break
    except Exception:
        pass
    # CLI override if explicitly provided
    if args.notify_chat_id:
        notify_chat = args.notify_chat_id
    if args.notify_topic_id:
        notify_topic = args.notify_topic_id

    # Validation
    if args.action in ("create", "edit", "install") and not args.agent_id:
        raise SystemExit("--agent-id required for create/edit/install")
    if args.action in ("create", "edit", "install") and not args.prompts_dir:
        raise SystemExit("--prompts-dir required for create/edit/install")
    if args.action == "install" and not args.repo_url:
        raise SystemExit("--repo-url required for install")
    if args.prompts_dir:
        pd = Path(args.prompts_dir)
        if not pd.is_dir():
            raise SystemExit(f"Prompts dir not found: {args.prompts_dir}")

    # ── PROMPT FILE GATE ──────────────────────────────────────
    # Validate ALL required prompt files exist BEFORE launching pipeline.
    # If CTO forgot SMOKE or VERIFY, this blocks and returns a clear error.
    # CTO sees the error, writes the missing files, and retries.
    if args.action == "create" and args.prompts_dir:
        pd = Path(args.prompts_dir)
        t_files = sorted(pd.glob("T[0-9][0-9].txt"))
        # Also check for wrong naming (T1.txt instead of T01.txt) and give clear error
        t_wrong = sorted(set(pd.glob("T*.txt")) - set(t_files))
        if t_wrong and not t_files:
            print(json.dumps({
                "ok": False,
                "error": f"BLOCKED: Prompt files use wrong naming. Use T01.txt-T08.txt (with leading zero), not {', '.join(f.name for f in t_wrong)}.",
                "found": [f.name for f in t_wrong],
            }))
            return 1
        if not t_files:
            print(json.dumps({"ok": False, "error": "BLOCKED: No T01-T08 prompt files found. Write T01.txt through T08.txt (leading zero required)."}))
            return 1
        if len(t_files) < 3:
            print(json.dumps({
                "ok": False,
                "error": f"BLOCKED: Only {len(t_files)} T-files found. Need at least 3 (research + code + verification).",
                "existing": [f.name for f in t_files],
            }))
            return 1
        if t_wrong:
            log(f"WARNING: Ignoring wrongly named files: {[f.name for f in t_wrong]}")
        log(f"Prompt gate passed: {len(t_files)} T-files")

    elif args.action == "edit" and args.prompts_dir:
        pd = Path(args.prompts_dir)
        if not (pd / "FIX.txt").exists():
            print(json.dumps({"ok": False, "error": "BLOCKED: FIX.txt required for edit pipeline."}))
            return 1

    elif args.action == "install" and args.prompts_dir:
        pd = Path(args.prompts_dir)
        if not (pd / "INSTALL.txt").exists():
            print(json.dumps({"ok": False, "error": "BLOCKED: INSTALL.txt required for install pipeline."}))
            return 1

    # Build lobster command
    if args.action == "create":
        lobster_file = f"{factory}/lobster/create-agent.lobster"
        workspace = f"{root}/workspace-{args.agent_id}"
        lobster_args = {
            "agent_id": args.agent_id,
            "openclaw_root": root,
            "prompts_dir": args.prompts_dir,
            "workspace": workspace,
            "chat_id": args.chat_id,
            "topic_id": args.topic_id,
            "test_cmd": args.test_cmd,
        }
    elif args.action == "edit":
        lobster_file = f"{factory}/lobster/edit-agent.lobster"
        lobster_args = {
            "agent_id": args.agent_id,
            "openclaw_root": root,
            "prompts_dir": args.prompts_dir,
            "chat_id": args.chat_id,
            "topic_id": args.topic_id,
            "test_cmd": args.test_cmd,
        }
        workspace = f"{root}/workspace-{args.agent_id}"
    elif args.action == "install":
        lobster_file = f"{factory}/lobster/install-community-agent.lobster"
        lobster_args = {
            "agent_id": args.agent_id,
            "openclaw_root": root,
            "prompts_dir": args.prompts_dir,
            "repo_url": args.repo_url,
            "chat_id": args.chat_id,
            "topic_id": args.topic_id,
        }
        workspace = f"{root}/workspace-{args.agent_id}"
    else:
        lobster_file = f"{factory}/lobster/system-diagnostic.lobster"
        lobster_args = {"openclaw_root": root, "chat_id": args.chat_id, "topic_id": args.topic_id}
        workspace = ""

    if not Path(lobster_file).exists():
        raise SystemExit(f"Lobster file not found: {lobster_file}")

    cmd = ["lobster", "run", "--mode", "tool", "--file", lobster_file, "--args-json", json.dumps(lobster_args)]

    # Sanitize paths in prompt files (fix OPENCLAW_ROOT refs, ~/.openclaw, etc.)
    if args.prompts_dir:
        sanitize_prompt_paths(args.prompts_dir, root, workspace if workspace else "", args.agent_id or "")

    # Count prompt files
    prompt_count = 0
    if args.prompts_dir:
        prompt_count = len(list(Path(args.prompts_dir).glob("*.txt")))

    # Build env with LOBSTER_ARG_* vars
    lobster_env = os.environ.copy()
    for k, v in lobster_args.items():
        lobster_env[f"LOBSTER_ARG_{k.upper()}"] = str(v)

    # ── SPAWN OR RUN ──────────────────────────────────────────
    log_dir = Path(root) / "workspace-factory" / ".cto-brain" / "runtime"
    log_dir.mkdir(parents=True, exist_ok=True)

    # ── DEDUP GUARD ────────────────────────────────────────────
    # Prevent double-launch: if a build is already running for this agent, block.
    if args.agent_id and not is_background:
        progress_file = log_dir / "build_progress.json"
        if progress_file.exists():
            try:
                prev = json.loads(progress_file.read_text())
                if prev.get("status") == "running" and prev.get("agent_id") == args.agent_id:
                    # Check if the process is actually alive
                    started = prev.get("started_at", "")
                    print(json.dumps({
                        "ok": False,
                        "blocked": True,
                        "reason": "build_already_running",
                        "agent_id": args.agent_id,
                        "started_at": started,
                    }))
                    return 1
            except (json.JSONDecodeError, KeyError):
                pass  # Malformed progress file, proceed

    if not is_background:
        # Parent process — spawn ourselves as detached subprocess and return immediately
        log_path = str(log_dir / "launch_build.log")
        bg_cmd = [
            sys.executable, __file__,
            "--action", args.action,
            "--agent-id", args.agent_id or "",
            "--prompts-dir", args.prompts_dir or "",
            "--chat-id", args.chat_id,
            "--topic-id", args.topic_id,
            "--test-cmd", args.test_cmd,
            "--timeout", str(args.timeout),
            "--_background",
        ]
        if args.repo_url:
            bg_cmd += ["--repo-url", args.repo_url]

        with open(log_path, "w") as lf:
            proc = subprocess.Popen(
                bg_cmd,
                stdout=lf,
                stderr=lf,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
                env=lobster_env,
                cwd=factory,
            )

        print(json.dumps({
            "ok": True,
            "status": "launched",
            "pid": proc.pid,
            "agent_id": args.agent_id or "",
            "prompts": prompt_count,
            "progress_file": str(log_dir / "build_progress.json"),
        }))
        return 0

    # ── BACKGROUND MODE — run pipeline directly ──────────────

    # Clear stale failure_notified flag from previous runs
    flag_file = log_dir / "failure_notified"
    if flag_file.exists():
        flag_file.unlink()

    # Init progress tracking
    progress = {
        "agent_id": args.agent_id or "",
        "action": args.action,
        "status": "running",
        "current_step": "launching",
        "completed_steps": [],
        "elapsed_seconds": 0,
        "workspace_stats": {},
        "error": "",
        "resume_token": "",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "updated_at": "",
    }
    write_progress(root, progress)

    # Launch lobster
    started = time.time()
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=factory, env=lobster_env)
    except FileNotFoundError:
        msg = "❌ 'lobster' CLI not found. Install: npm install -g @clawdbot/lobster"
        log(msg)
        notify(notify_chat, notify_topic, msg)
        progress["status"] = "failed"
        progress["error"] = "lobster CLI not found"
        write_progress(root, progress)
        return 1

    # Monitor loop
    last_step = None
    last_report_time = started
    completed_steps = 0

    while proc.poll() is None:
        elapsed = int(time.time() - started)

        # Detect current step
        current_step = detect_active_step(args.prompts_dir or "")

        # Step changed — report it
        if current_step and current_step != last_step:
            label = STEP_LABELS.get(current_step, f"📋 {current_step}")
            log(f"{label} started ({elapsed}s)")
            notify(notify_chat, notify_topic, f"{label} started... ({elapsed}s elapsed)")

            # Report completion of previous step
            if last_step:
                prev_label = STEP_LABELS.get(last_step, last_step)
                completed_steps += 1
                ws_info = count_workspace_files(workspace) if workspace else {}
                extra = ""
                if ws_info.get("py_files"):
                    extra = f" | {ws_info['py_files']} py files, {ws_info.get('test_files', 0)} tests"
                log(f"  ✅ {prev_label} done{extra}")
                if last_step not in progress["completed_steps"]:
                    progress["completed_steps"].append(last_step)
                progress["workspace_stats"] = ws_info

            last_step = current_step
            last_report_time = time.time()

            # Update progress file
            progress["current_step"] = current_step
            progress["elapsed_seconds"] = elapsed
            write_progress(root, progress)

        # Periodic heartbeat (every 90s if no step change)
        elif time.time() - last_report_time >= 90:
            ws_info = count_workspace_files(workspace) if workspace else {}
            step_str = STEP_LABELS.get(last_step, last_step) if last_step else "initializing"
            extra = ""
            if ws_info.get("py_files"):
                extra = f" | {ws_info['py_files']} py, {ws_info.get('test_files', 0)} tests"
            log(f"⏳ Still running: {step_str} ({elapsed}s){extra}")
            last_report_time = time.time()
            # Update progress on heartbeat too
            progress["elapsed_seconds"] = elapsed
            progress["workspace_stats"] = ws_info
            write_progress(root, progress)

        # Timeout check
        if elapsed > args.timeout:
            proc.kill()
            msg = f"⏰ TIMEOUT: Pipeline killed after {args.timeout}s"
            log(msg)
            notify(notify_chat, notify_topic, msg)
            return 124

        time.sleep(5)

    # Process finished
    stdout = proc.stdout.read()
    stderr = proc.stderr.read()
    elapsed = int(time.time() - started)

    if proc.returncode != 0:
        error_detail = stderr[:500] if stderr else stdout[:500]
        msg = f"❌ <b>Pipeline failed</b> (exit {proc.returncode}, {elapsed}s)\n<pre>{error_detail}</pre>"
        log(f"FAILED: exit {proc.returncode} after {elapsed}s")
        log(f"  {error_detail}")
        notify(notify_chat, notify_topic, msg)
        progress["status"] = "failed"
        progress["error"] = error_detail
        progress["elapsed_seconds"] = elapsed
        write_progress(root, progress)
        print(json.dumps({"ok": False, "exit_code": proc.returncode, "elapsed": elapsed, "error": error_detail}))
        return proc.returncode

    # Parse lobster JSON output
    try:
        result = json.loads(stdout)
    except (json.JSONDecodeError, ValueError):
        log(f"Completed in {elapsed}s (non-JSON output)")
        ws_info = count_workspace_files(workspace) if workspace else {}
        msg = f"✅ <b>Pipeline completed</b> ({elapsed}s)"
        if ws_info.get("py_files"):
            msg += f"\n{ws_info['py_files']} Python files, {ws_info.get('test_files', 0)} test files"
        notify(notify_chat, notify_topic, msg)
        print(json.dumps({"ok": True, "status": "completed", "elapsed": elapsed}))
        return 0

    if result.get("ok"):
        status = result.get("status", "ok")
        if status == "needs_approval":
            approval = result.get("requiresApproval", {})
            token = approval.get("resumeToken", "")
            items = approval.get("items", [])
            msg = (
                f"🔒 <b>Approval needed</b> ({elapsed}s)\n"
                f"Items: {json.dumps(items)}\n"
                f"Reply YES to approve or NO to reject."
            )
            log(f"APPROVAL NEEDED after {elapsed}s")
            notify(notify_chat, notify_topic, msg)
            progress["status"] = "approval_needed"
            progress["resume_token"] = token
            progress["elapsed_seconds"] = elapsed
            write_progress(root, progress)
            print(json.dumps({
                "ok": True, "status": "needs_approval",
                "elapsed": elapsed, "resume_token": token, "items": items,
            }, indent=2))
        else:
            ws_info = count_workspace_files(workspace) if workspace else {}
            msg = f"✅ <b>Build complete: {args.agent_id}</b> ({elapsed}s)"
            if ws_info.get("py_files"):
                msg += f"\n📦 {ws_info['py_files']} Python files, {ws_info.get('test_files', 0)} test files"
            log(f"SUCCESS after {elapsed}s")
            notify(notify_chat, notify_topic, msg)
            progress["status"] = "completed"
            progress["elapsed_seconds"] = elapsed
            progress["workspace_stats"] = ws_info
            write_progress(root, progress)
            print(json.dumps({"ok": True, "status": "completed", "elapsed": elapsed}, indent=2))
    else:
        error = result.get("error", {}).get("message", "unknown")
        msg = f"❌ <b>Pipeline failed</b>: {error} ({elapsed}s)"
        log(f"PIPELINE FAILED: {error}")
        notify(notify_chat, notify_topic, msg)
        progress["status"] = "failed"
        progress["error"] = error
        progress["elapsed_seconds"] = elapsed
        write_progress(root, progress)
        print(json.dumps({"ok": False, "error": error, "elapsed": elapsed}, indent=2))
        return 1

    return 0


def log(msg: str):
    """Timestamped log to stderr (visible in process logs)."""
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
