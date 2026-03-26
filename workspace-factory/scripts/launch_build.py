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


def sanitize_prompt_paths(prompts_dir: str, root: str, workspace: str):
    """Replace unresolved variables in prompt files with absolute paths.
    CTO often writes $OPENCLAW_ROOT or ~/.openclaw instead of real paths.
    """
    home = str(Path.home())
    pd = Path(prompts_dir)
    replacements = [
        ("$OPENCLAW_ROOT", root),
        ("${OPENCLAW_ROOT}", root),
        ("~/.openclaw", root),
        ("$HOME/.openclaw", root),
        ("${HOME}/.openclaw", root),
        ("$WORKSPACE", workspace),
        ("${WORKSPACE}", workspace),
    ]
    for f in pd.glob("*.txt"):
        content = f.read_text()
        original = content
        for old, new in replacements:
            content = content.replace(old, new)
        # Also replace bare ~ at start of paths (~/anything)
        content = re.sub(r'(?<!\w)~/', f'{home}/', content)
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
    """Send a Telegram notification via openclaw CLI. Silent fail if no chat_id."""
    if not chat_id:
        return
    cmd = ["openclaw", "message", "send", "--channel", "telegram"]
    target = chat_id
    if topic_id:
        target = f"{chat_id}:topic:{topic_id}"
    cmd += ["--target", target, "-m", message]
    try:
        subprocess.run(cmd, capture_output=True, timeout=15)
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
    p.add_argument("--notify-chat-id", default="", help="Telegram chat ID for BUILD notifications (CTO's topic)")
    p.add_argument("--notify-topic-id", default="", help="Telegram topic ID for BUILD notifications (CTO's topic)")
    p.add_argument("--test-cmd", default="python3 -m pytest -q", help="Test runner command")
    p.add_argument("--timeout", type=int, default=7200, help="Max runtime in seconds (default: 2h)")
    args = p.parse_args()

    root = find_openclaw_root()
    factory = f"{root}/workspace-factory"

    # Resolve notification target: use --notify-* if provided, otherwise fall back to --chat-id/--topic-id
    notify_chat = args.notify_chat_id or args.chat_id
    notify_topic = args.notify_topic_id or args.topic_id

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
            "notify_chat_id": notify_chat,
            "notify_topic_id": notify_topic,
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
            "notify_chat_id": notify_chat,
            "notify_topic_id": notify_topic,
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
            "notify_chat_id": notify_chat,
            "notify_topic_id": notify_topic,
        }
        workspace = f"{root}/workspace-{args.agent_id}"
    else:
        lobster_file = f"{factory}/lobster/system-diagnostic.lobster"
        lobster_args = {"openclaw_root": root, "chat_id": args.chat_id, "topic_id": args.topic_id}
        workspace = ""

    if not Path(lobster_file).exists():
        raise SystemExit(f"Lobster file not found: {lobster_file}")

    cmd = ["lobster", "run", "--mode", "tool", "--file", lobster_file, "--args-json", json.dumps(lobster_args)]

    # Sanitize paths in prompt files (fix $OPENCLAW_ROOT, ~/.openclaw, etc.)
    if args.prompts_dir:
        sanitize_prompt_paths(args.prompts_dir, root, workspace if workspace else "")

    # Count prompt files
    prompt_count = 0
    if args.prompts_dir:
        prompt_count = len(list(Path(args.prompts_dir).glob("*.txt")))

    # Self-daemonize: fork so parent returns immediately (CTO's session unlocks)
    pid = os.fork()
    if pid > 0:
        # Parent — return immediately with launch confirmation
        print(json.dumps({
            "ok": True,
            "status": "launched",
            "pid": pid,
            "agent_id": args.agent_id or "",
            "prompts": prompt_count,
            "progress_file": f"{root}/workspace-factory/.cto-brain/runtime/build_progress.json",
        }))
        return 0
    # Child — continue with pipeline execution
    # Detach from parent's session
    os.setsid()
    # Redirect stdin/stdout/stderr to prevent broken pipe after parent exits
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)  # stdin
    # Keep stdout/stderr going to a log file so we can debug
    log_dir = Path(root) / "workspace-factory" / ".cto-brain" / "runtime"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = os.open(str(log_dir / "launch_build.log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(log_file, 1)  # stdout → log file
    os.dup2(log_file, 2)  # stderr → log file
    os.close(devnull)
    os.close(log_file)

    # Notify start
    log(f"🚀 Launching {args.action} pipeline for {args.agent_id or 'system'}")
    log(f"Lobster: {lobster_file}")
    log(f"Prompts: {prompt_count} files")
    notify(
        args.chat_id, args.topic_id,
        f"🚀 <b>Build started: {args.agent_id or 'diagnostic'}</b>\n"
        f"Action: {args.action}\n"
        f"Prompt files: {prompt_count}\n"
        f"Timeout: {args.timeout // 60}m"
    )

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

    # Build env with LOBSTER_ARG_* vars so shell commands in .lobster can read them
    lobster_env = os.environ.copy()
    for k, v in lobster_args.items():
        lobster_env[f"LOBSTER_ARG_{k.upper()}"] = str(v)

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
            notify(
                args.chat_id, args.topic_id,
                f"⏳ Still running: {step_str} ({elapsed}s){extra}"
            )
            last_report_time = time.time()

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
