#!/usr/bin/env python3
"""Register an agent in openclaw.json with optional Telegram binding and auth copy."""
import json
import pathlib
import shutil
import sys


def main():
    if len(sys.argv) < 4:
        print('Usage: lobster_register_agent.py <config_path> <agent_id> <workspace> [chat_id] [topic_id]', file=sys.stderr)
        sys.exit(1)

    config_path = pathlib.Path(sys.argv[1])
    agent_id = sys.argv[2]
    workspace = sys.argv[3]
    chat_id = sys.argv[4] if len(sys.argv) > 4 else ""
    topic_id = sys.argv[5] if len(sys.argv) > 5 else ""

    import re as _re
    raw = config_path.read_text()
    # Fix trailing commas (code agent sometimes adds them)
    raw = _re.sub(r',(\s*[}\]])', r'\1', raw)
    d = json.loads(raw)

    # --- Register agent ---
    agents = d.setdefault("agents", {}).setdefault("list", [])
    found = False
    for a in agents:
        if a.get("id") == agent_id:
            a["workspace"] = workspace
            a["agentDir"] = workspace
            found = True
            break

    if not found:
        agents.append({
            "id": agent_id,
            "default": False,
            "name": agent_id.replace("-", " ").title(),
            "workspace": workspace,
            "agentDir": workspace,
            "model": {"primary": "anthropic/claude-sonnet-4-6"},
            "identity": {"name": agent_id.replace("-", " ").title()},
        })

    # --- Create Telegram binding (if chat_id provided) ---
    binding_created = False
    if chat_id:
        bindings = d.setdefault("bindings", [])
        peer_id = f"{chat_id}:topic:{topic_id}" if topic_id else chat_id
        # Check if binding already exists
        exists = any(
            b.get("agentId") == agent_id
            and b.get("match", {}).get("peer", {}).get("id") == peer_id
            for b in bindings
        )
        if not exists:
            bindings.append({
                "agentId": agent_id,
                "match": {
                    "channel": "telegram",
                    "accountId": "default",
                    "peer": {
                        "kind": "group",
                        "id": peer_id,
                    }
                }
            })
            binding_created = True

    # --- Write config ---
    config_path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")

    # --- Copy auth-profiles.json from best available source ---
    auth_copied = False
    root = config_path.parent
    ws_path = pathlib.Path(workspace)
    dst = ws_path / "auth-profiles.json"
    # Search order: CTO agent (most likely to have OAuth), then main, then root
    candidates = [
        root / "agents" / "cto-factory" / "agent" / "auth-profiles.json",
        root / "agents" / "main" / "auth-profiles.json",
        root / "auth-profiles.json",
    ]
    # Also check any existing agent dirs
    agents_dir = root / "agents"
    if agents_dir.is_dir():
        for agent_dir in sorted(agents_dir.iterdir()):
            ap = agent_dir / "agent" / "auth-profiles.json"
            if ap.exists() and ap not in candidates:
                candidates.append(ap)
    for src in candidates:
        if src.exists() and src != dst:
            shutil.copy2(src, dst)
            auth_copied = True
            break

    print(json.dumps({
        "ok": True,
        "registered": agent_id,
        "found_existing": found,
        "binding_created": binding_created,
        "binding_peer": f"{chat_id}:topic:{topic_id}" if chat_id else "",
        "auth_copied": auth_copied,
    }))


if __name__ == "__main__":
    main()
