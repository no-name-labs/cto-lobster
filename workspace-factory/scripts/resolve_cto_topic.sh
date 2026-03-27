#!/usr/bin/env bash
# Resolve CTO Factory Telegram target from openclaw.json binding.
# Prints the peer ID (e.g. -1003633569118:topic:1269) or empty string.
OPENCLAW_ROOT="${1:-${OPENCLAW_HOME:-$HOME/.openclaw}}"
python3 -c "
import json
d=json.load(open('${OPENCLAW_ROOT}/openclaw.json'))
for b in d.get('bindings',[]):
    if b.get('agentId')=='cto-factory':
        print(b['match']['peer']['id']); break
" 2>/dev/null
