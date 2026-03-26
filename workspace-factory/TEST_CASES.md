# CTO Factory — Manual Test Cases

## Pre-requisites
- OpenClaw gateway running (`openclaw gateway status` → probe: ok)
- CTO agent registered and bound to Telegram topic
- Clean state: no pending builds, no stale sessions

---

## TC1: Agent Creation (Happy Path)
**Goal:** CTO creates a working agent from a simple prompt.

1. Send to CTO: `I want an agent that checks https://status.claude.com/ every 10 minutes and sends me a Telegram message if anything is degraded`
2. **Expect:** CTO asks 2-4 questions with A/B/C options (data source, schedule, delivery target, Telegram topic)
3. Answer the questions
4. **Expect:** CTO presents sign-off with: mission, requirements list, technical decisions, implementation plan (T1-T6), Telegram binding, defaults. Sign-off has inline buttons (YES/REVISE/STOP)
5. Press YES button (or type YES)
6. **Expect:** CTO writes 9 prompt files (RESEARCH + T1-T6 + SMOKE + VERIFY) and launches pipeline
7. **Expect:** Notifications arrive in CTO's topic (not agent's topic): 🚀 Build started, 🔬 Research, 🏗️ T1, etc.
8. **Expect:** Pipeline reaches approval gate. CTO sends approval message with buttons (APPROVE/REJECT)
9. Press APPROVE
10. **Expect:** Agent registered, bound to specified topic, responds to commands

**Pass criteria:**
- [ ] Intake asked about all 8 required inputs
- [ ] Sign-off had implementation plan T1-T6
- [ ] SMOKE.txt and VERIFY.txt were written (9 files total)
- [ ] Notifications went to CTO topic, not agent topic
- [ ] Gateway survived restart
- [ ] Agent responds to commands
- [ ] Tests pass (`python3 -m pytest tests/ -q` in workspace)

---

## TC2: Agent Creation with Secrets
**Goal:** CTO handles secret collection properly.

1. Send: `Build me an agent that uses the GitHub API to find trending repos and sends a daily digest`
2. **Expect:** CTO identifies GITHUB_TOKEN as required secret
3. CTO asks how to provide the secret
4. Provide a test token
5. **Expect:** CTO verifies secret exists in .env before launching pipeline
6. Pipeline builds agent that reads GITHUB_TOKEN from env

**Pass criteria:**
- [ ] CTO identified the secret during intake
- [ ] Secret listed in sign-off
- [ ] CTO verified secret before build
- [ ] Agent code uses os.environ, not hardcoded

---

## TC3: Agent Editing
**Goal:** CTO modifies an existing agent via edit pipeline.

1. Create an agent first (TC1)
2. Send: `Change the reddit-pain-finder to also track positive sentiment, not just pain points`
3. **Expect:** CTO reads current agent files (IDENTITY.md, PROMPTS.md, code)
4. **Expect:** CTO writes FIX.txt (not T1-T6) with change description + current state summary
5. **Expect:** Edit pipeline runs: FIX → validate → tests → restart → smoke → verify
6. **Expect:** Notifications in CTO topic for each stage
7. **Expect:** Agent still works after edit, with new capability

**Pass criteria:**
- [ ] CTO read existing agent before writing FIX.txt
- [ ] FIX.txt used (not T1-T6)
- [ ] Edit pipeline completed
- [ ] Tests still pass
- [ ] Agent responds with new capability

---

## TC4: Community Agent Install
**Goal:** CTO installs an agent from GitHub repo.

1. Send: `Install notes-agent from https://github.com/smart-spine/openclaw-notes-agent`
2. **Expect:** CTO fetches README, identifies required inputs (bot token, group ID, assignees)
3. **Expect:** CTO asks for secrets/config
4. Provide test values
5. **Expect:** CTO writes INSTALL.txt + VERIFY.txt, launches install pipeline
6. **Expect:** Pipeline: clone → install → validate → restart → smoke → verify

**Pass criteria:**
- [ ] CTO read README
- [ ] CTO identified all required inputs from README
- [ ] INSTALL.txt had exact install command
- [ ] Agent installed and responds

---

## TC5: OpenClaw Operations
**Goal:** CTO manages OpenClaw through ops scripts.

### TC5a: Read-only ops
1. Send: `What agents are running?`
2. **Expect:** CTO runs `ops/agent_list.py` and reports results

3. Send: `Is the gateway healthy?`
4. **Expect:** CTO runs `ops/gateway_status.py` and reports

5. Send: `Show me all cron jobs`
6. **Expect:** CTO runs `ops/cron_list.py` and reports

### TC5b: Cron management
1. Send: `Set up a daily cron for reddit-pain-finder at 8am UTC`
2. **Expect:** CTO runs `ops/cron_create.py` with correct args
3. **Expect:** CTO reports JSON result to user

4. Send: `Delete that cron job`
5. **Expect:** CTO runs `ops/cron_delete.py`

### TC5c: Gateway restart
1. Send: `Restart the gateway`
2. **Expect:** CTO runs `ops/gateway_restart.py` or asks for confirmation first

**Pass criteria:**
- [ ] CTO used ops scripts, not raw openclaw commands
- [ ] CTO reported full JSON results
- [ ] Operations completed successfully

---

## TC6: Fault Tolerance
**Goal:** CTO handles failures gracefully.

### TC6a: Pipeline failure
1. Start a build (TC1)
2. During build, kill the gateway: `openclaw gateway stop`
3. Wait for pipeline to fail
4. **Expect:** CTO detects failure and reports to user
5. **Expect:** CTO suggests fix (restart gateway)

### TC6b: Missing files
1. Start a build where CTO "forgets" SMOKE.txt
2. **Expect:** launch_build.py gate blocks with "BLOCKED: Missing SMOKE.txt"
3. **Expect:** CTO writes the missing file and retries

### TC6c: Progress monitoring
1. Start a build
2. During build, ask CTO: `What's the status?`
3. **Expect:** CTO reads build_progress.json and reports current step, completed steps, elapsed time

**Pass criteria:**
- [ ] CTO detected and reported failures
- [ ] CTO suggested recovery steps
- [ ] CTO could report build status when asked

---

## TC7: Notification System
**Goal:** All notifications go to the right place.

1. Start a build with CTO in topic 1269, agent target in topic 1655
2. **Expect:** Build progress notifications (🚀, 🔬, 🏗️, etc.) appear in topic 1269 (CTO)
3. **Expect:** NO build notifications in topic 1655 (agent)
4. **Expect:** build_monitor.sh cron sends heartbeat every 5 min to CTO topic
5. **Expect:** BUILD_DONE callback triggers CTO to send final report in CTO topic

**Pass criteria:**
- [ ] All stage notifications in CTO topic
- [ ] Zero notifications in agent topic during build
- [ ] Heartbeat from build_monitor.sh working
- [ ] Final report from CTO after completion

---

## TC8: Buttons
**Goal:** Inline buttons work for sign-off and approval.

1. Start agent creation
2. **Expect:** Sign-off message has clickable buttons (YES/REVISE/STOP)
3. Click YES button
4. **Expect:** CTO starts build without needing text confirmation
5. Wait for approval gate
6. **Expect:** Approval message has clickable buttons (APPROVE/REJECT)
7. Click APPROVE
8. **Expect:** Pipeline resumes

**Pass criteria:**
- [ ] Buttons rendered in Telegram
- [ ] Button click triggers correct action
- [ ] No text input required

---

## Quick Smoke Test (5 min)

Run these in order for a quick validation:

```bash
# 1. Gateway alive
openclaw gateway status | grep probe

# 2. CTO responds
openclaw agent --agent cto-factory --message "hello" --timeout 30 --json | head -5

# 3. Ops scripts work
python3 ~/.openclaw/workspace-factory/scripts/ops/gateway_status.py
python3 ~/.openclaw/workspace-factory/scripts/ops/agent_list.py
python3 ~/.openclaw/workspace-factory/scripts/ops/config_validate.py

# 4. build_monitor.sh syntax OK
bash -n ~/.openclaw/workspace-factory/scripts/build_monitor.sh && echo "OK"

# 5. launch_build.py gate works
mkdir -p /tmp/test-gate && echo "test" > /tmp/test-gate/T1.txt
python3 ~/.openclaw/workspace-factory/scripts/launch_build.py --action create --agent-id test --prompts-dir /tmp/test-gate 2>&1
# Should output: BLOCKED: Missing required prompt files: SMOKE.txt, VERIFY.txt
rm -rf /tmp/test-gate
```
