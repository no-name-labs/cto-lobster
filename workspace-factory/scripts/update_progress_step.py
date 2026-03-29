#!/usr/bin/env python3
"""Update build_progress.json step fields (called by lobster pipeline).

Usage:
  update_progress_step.py <progress_file> start <step_name>
  update_progress_step.py <progress_file> done <step_name> [py_files] [test_count]
"""
import json
import sys
import time


def main():
    if len(sys.argv) < 4:
        print("Usage: update_progress_step.py <file> start|done <step>", file=sys.stderr)
        return 1

    path = sys.argv[1]
    action = sys.argv[2]  # "start" or "done"
    step = sys.argv[3]
    py_files = sys.argv[4] if len(sys.argv) > 4 else ""
    test_count = sys.argv[5] if len(sys.argv) > 5 else ""

    try:
        with open(path) as f:
            p = json.load(f)
    except Exception:
        return 1

    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    if action == "start":
        p["current_step"] = step
    elif action == "done":
        p["current_step"] = f"{step} (done)"
        cs = p.get("completed_steps", [])
        if step not in cs:
            cs.append(step)
        p["completed_steps"] = cs
        if py_files or test_count:
            p["workspace_stats"] = {"py_files": py_files, "tests": test_count}

    p["updated_at"] = now

    with open(path, "w") as f:
        json.dump(p, f, indent=2)

    return 0


if __name__ == "__main__":
    sys.exit(main())
