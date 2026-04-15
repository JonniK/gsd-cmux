---
name: gsd-omc-bridge
description: How a GSD executor subagent runs a single plan as an OMC team worker — claim a pre-assigned task, execute the plan, write SUMMARY.md, transition to completed. Load when you are a gsd-executor running inside an omc team pane (env `OMC_TEAM_WORKER` is set).
type: skill
---

# gsd-omc-bridge

You are a GSD executor running as one worker in an OMC team. Each worker owns **exactly one** pre-assigned plan. The orchestrator spawned you, created your task with `owner=<your-worker-name>`, and is polling for `status=completed`.

## OMC CLI response shape (read this first)

Every `omc team api <op> --json` call wraps the payload as:

```json
{"ok": true, "operation": "<op>", "data": { ... }}
```

All jq paths below go through `.data.*`. Task objects use `.id` (not `.task_id`), claim tokens use `.claimToken` (camelCase). Task states are `pending | blocked | in_progress | completed | failed`.

## Detect your context

OMC sets these env vars before your CLI started:

| Var | Example | Use |
|---|---|---|
| `OMC_TEAM_WORKER` | `gsd-phase5-ab12/worker-2` | `${OMC_TEAM_WORKER#*/}` → your worker name |
| `OMC_TEAM_NAME` | `gsd-phase5-ab12` | team name for all `omc team api` calls |
| `OMC_TEAM_STATE_ROOT` | `/path/to/.omc/teams/gsd-phase5-ab12` | (read-only reference) |
| `CMUX_SOCKET_PATH` | `/Users/.../cmux.sock` | set → you're in a cmux pane |

If `OMC_TEAM_WORKER` is empty you are **not** an OMC worker — abort this skill, you're in the wrong context.

## Lifecycle (execute in order)

### 1. Identify

```bash
TEAM="$OMC_TEAM_NAME"
ME="${OMC_TEAM_WORKER#*/}"      # "worker-1", "worker-2", …
```

### 2. Find your pre-assigned task

Poll `list-tasks` until you see a task whose `owner == $ME` and `status == "pending"`. Wait up to 60s; the orchestrator creates tasks **after** spawning workers.

```bash
for i in $(seq 1 12); do
  TASKS=$(omc team api list-tasks --input "{\"team_name\":\"$TEAM\"}" --json)
  MINE=$(jq -r --arg me "$ME" '.data.tasks[] | select(.owner==$me and .status=="pending") | .id' <<<"$TASKS" | head -1)
  [ -n "$MINE" ] && break
  sleep 5
done
[ -z "$MINE" ] && { echo "no task assigned after 60s" >&2; exit 1; }
TID="$MINE"
```

### 3. Claim — save the claim_token

```bash
RESP=$(omc team api claim-task --input \
  "{\"team_name\":\"$TEAM\",\"task_id\":\"$TID\",\"worker\":\"$ME\"}" --json)
CLAIM_TOKEN=$(jq -r .data.claimToken <<<"$RESP")
```

Claiming moves the task `pending → in_progress`. The `claimToken` is required for every later state transition. **Lose it and you cannot mark the task completed.** Hold it in a shell var; do not write it to disk.

### 4. Parse the plan pointer

The task description is a triple-bar-separated pointer written by the orchestrator:

```
gsd-plan:<plan-id>|<plan-path>|<summary-path>
```

```bash
DESC=$(omc team api read-task --input "{\"team_name\":\"$TEAM\",\"task_id\":\"$TID\"}" --json | jq -r .data.task.description)
PLAN_ID=$(awk -F'|' '{print $1}' <<<"$DESC" | sed 's/^gsd-plan://')
PLAN_PATH=$(awk -F'|' '{print $2}' <<<"$DESC")
SUMMARY_PATH=$(awk -F'|' '{print $3}' <<<"$DESC")
```

### 5. Execute the plan

Read `$PLAN_PATH` (a `PLAN-<id>.md` under `.planning/phases/<phase>/plans/`). Follow it exactly — do not re-plan, do not expand scope. A GSD plan is a leaf deliverable, not a discussion.

If you need progress visible in cmux, `cmux log --source gsd-worker --level info "..."` (optional — the pane's stdout is already the primary signal).

### 6. Write SUMMARY.md

Write to `$SUMMARY_PATH` (create parent dir if needed). Required structure:

```markdown
# SUMMARY — <plan-id>

**Worker:** <worker-name>
**Task:** <task-id>
**Status:** completed

## What changed
- one-line bullets, files/behaviors, no prose

## Files
- path/to/file.ext — created|modified|deleted — reason

## Verification
- command run → result
- (commands the verifier can re-run)

## Caveats
- anything the orchestrator / verifier must know (none → write "none")
```

Non-empty "What changed" and "Files" sections are mandatory — the verifier gates on them.

### 7. Transition to completed

```bash
omc team api transition-task-status --input \
  "{\"team_name\":\"$TEAM\",\"task_id\":\"$TID\",\"from\":\"in_progress\",\"to\":\"completed\",\"claim_token\":\"$CLAIM_TOKEN\"}" \
  --json
```

Note: the CLI input flag is `claim_token` (snake_case), but the value you pass comes from `.data.claimToken` (camelCase) in the claim-task response.

Valid states: `pending → in_progress → completed | failed`. No "open", no "done". Use `failed` plus a mailbox message for blockers (separate from the `blocked` state, which is reserved for dependency-gated tasks).

### 8. Shutdown cleanly

After transition succeeds, exit 0. The pane stays for orchestrator inspection until `omc team api cleanup` is called.

## Failure paths

| Situation | Action |
|---|---|
| Plan unreadable or malformed | Send mailbox to `leader-fixed`; transition `in_progress → failed`; do **not** write SUMMARY.md |
| Plan executes but verification command fails | Write SUMMARY.md with `**Status:** failed` and the failing evidence; transition to `failed` |
| Work blocked on another worker / external input | Send mailbox to `leader-fixed` with body `blocked:<reason>`; transition to `failed` (v1 has no "pause") |
| Claim rejected (task already claimed) | Re-run step 2 — another task may be assigned to you, or you raced with yourself |

Blocker message template:

```bash
omc team api send-message --input "{
  \"team_name\":\"$TEAM\",
  \"from_worker\":\"$ME\",
  \"to_worker\":\"leader-fixed\",
  \"body\":\"blocked:<plan-id>:<one-line reason>\"
}" --json
```

## Non-negotiables

1. **One claim at a time.** Never call `claim-task` twice; you own one plan only.
2. **Never spawn child teams.** No `omc team ...`, no nested waves. Parallelism is owned by the orchestrator that spawned you.
3. **Always transition.** Every claim MUST end in `completed` or `failed`. Leaking `in_progress` tasks stalls the wave.
4. **Claim token is required** on every transition. Capture it at step 3 and never lose it.
5. **Do not modify `.planning/` outside your plan's scope.** The orchestrator reads the plan graph; touching other plans corrupts coordination.
6. **Respect the GSD phase contract.** SUMMARY.md is not a log — it's the handoff artifact the verifier reads.

## cmux invariants (for `cmux send` calls, if any)

If you use `cmux send` directly (most workers don't need to):

- Trailing `\n` on `cmux send --surface surface:N "cmd\n"` acts as Enter.
- Multi-line input: use `cmux send-key --surface surface:N return` between lines, not literal `\n\n`.
- Control keys: `cmux send-key --surface surface:N ctrl+c`.
- `--surface` only targets the current workspace; use `--workspace workspace:N` to cross workspaces.
- Run `cmux tree` first if you're not sure which workspace a surface belongs to.
