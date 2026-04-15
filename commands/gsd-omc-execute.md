---
description: Execute a GSD phase with each plan running as a visible cmux pane worker via OMC. Wave-gated. Writes per-plan SUMMARY.md files and a phase-level SUMMARY.md.
argument-hint: "<phase> [--resume] [--max-parallel N]"
---

# /gsd-omc-execute — single-phase OMC orchestrator

You are the **orchestrator**. Your job: take a planned GSD phase, run each `PLAN-*.md` in parallel where waves allow, collect `SUMMARY.md`s, gate on wave completion, and produce a phase-level `SUMMARY.md`.

You will NOT execute any plan yourself. Workers do that. You coordinate.

**Spec:** DESIGN.md §5 + skill `global:gsd-omc-bridge` (worker contract).

---

## Inputs

- `$1` — phase name (required). Normalizes via GSD's `find-phase`.
- `--resume` — skip waves whose tasks are already `completed`.
- `--max-parallel N` — cap concurrent panes. Defaults to env `GSD_OMC_MAX_PARALLEL` or `3`.

## Step 1 — Preflight

Run these in a single Bash block. Abort on any failure with a clear message.

```bash
set -euo pipefail

# Parse args (literal values captured below go into every subagent prompt)
PHASE="$1"
RESUME=0; MAX_PARALLEL="${GSD_OMC_MAX_PARALLEL:-3}"
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --resume) RESUME=1; shift;;
    --max-parallel) MAX_PARALLEL="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# Must be in cmux (panes are the whole point)
[ -n "${CMUX_SOCKET_PATH:-}" ] || { echo "✗ not inside cmux — open a cmux workspace first" >&2; exit 1; }

# Binaries
for c in omc cmux claude node jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "✗ missing binary: $c" >&2; exit 1; }
done

# Phase exists and has plans
INDEX_JSON=$(node ~/.claude/get-shit-done/bin/gsd-tools.cjs phase-plan-index "$PHASE" --raw)
echo "$INDEX_JSON" | jq -e '.error // empty' >/dev/null && { echo "✗ phase not found: $PHASE" >&2; exit 1; }
PLAN_COUNT=$(jq '.plans | length' <<<"$INDEX_JSON")
[ "$PLAN_COUNT" -gt 0 ] || { echo "✗ phase $PHASE has no plans" >&2; exit 1; }

# Resolve phase dir (gsd-tools doesn't echo it; derive by globbing)
PHASE_DIR=$(ls -d .planning/phases/*"${PHASE}"* 2>/dev/null | head -1)
[ -d "$PHASE_DIR" ] || { echo "✗ cannot resolve phase directory for $PHASE" >&2; exit 1; }

echo "phase:   $PHASE"
echo "dir:     $PHASE_DIR"
echo "plans:   $PLAN_COUNT"
echo "waves:   $(jq -r '.waves | keys | join(",")' <<<"$INDEX_JSON")"
echo "budget:  $MAX_PARALLEL parallel panes"
```

Report the echoed summary to the user and continue.

## Step 2 — Prepare team state

```bash
# Team name must match OMC regex ^[a-z0-9][a-z0-9-]{0,63}$
RAND=$(od -An -N2 -i /dev/urandom | tr -d ' ')
TEAM="gsd-$(echo "$PHASE" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]//g')-${RAND}"
OMC_DIR="$PHASE_DIR/.omc"
mkdir -p "$OMC_DIR"
echo "$TEAM" > "$OMC_DIR/team.txt"
echo "team:    $TEAM"
```

**Record `$TEAM` as a literal value.** Every subsequent Bash block in this command re-reads `"$OMC_DIR/team.txt"` — do NOT assume env inheritance across tool calls (memory: literal substitution).

## Step 3 — Iterate waves

For each wave key in sorted order (`1`, `2`, …):

### 3a. Load wave

```bash
TEAM=$(cat "$OMC_DIR/team.txt")
WAVE_KEY="<wave-n>"   # literal: "1", "2", ...
PLANS_IN_WAVE=$(jq -r --arg w "$WAVE_KEY" '.waves[$w][] // empty' <<<"$INDEX_JSON")
COUNT=$(echo "$PLANS_IN_WAVE" | grep -c . || echo 0)
[ "$COUNT" -gt 0 ] || { echo "wave $WAVE_KEY empty, skipping"; continue; }
```

If `--resume`: skip this wave if every plan's SUMMARY.md already exists and is non-empty.

### 3b. Spawn N workers BEFORE creating tasks

Workers self-identify via `$OMC_TEAM_WORKER` env. OMC names them `worker-1..worker-N` in spawn order. The adapter skill (`global:gsd-omc-bridge`) teaches them the lifecycle.

```bash
cmux log --source gsd-orch --level info "wave $WAVE_KEY: spawning $COUNT panes"
# Cap concurrency — spawn in batches of MAX_PARALLEL; each batch blocks
# until its tasks complete before the next batch begins.
BATCH_SIZE="$MAX_PARALLEL"

# Bootstrap prompt is static. Workers read $OMC_TEAM_WORKER themselves.
BOOTSTRAP="You are a GSD executor inside OMC team \$OMC_TEAM_NAME as \$OMC_TEAM_WORKER. Load the gsd-omc-bridge skill (it is in your agent_skills) and execute the lifecycle it describes. Exit when your assigned task transitions to completed or failed."

omc team "$COUNT:claude:executor" "$BOOTSTRAP" \
  --team-name "$TEAM" \
  --new-window
```

Wait ~5s for panes to register:

```bash
sleep 5
omc team status "$TEAM"
```

Verify workers are alive. Parse worker names from `omc team api read-config`:

```bash
WORKER_NAMES=$(omc team api read-config --input "{\"team_name\":\"$TEAM\"}" --json \
  | jq -r '.config.workers[].name')
echo "$WORKER_NAMES"
```

### 3c. Create pre-assigned tasks (one per plan, `owner=<worker-name>`)

Pair each planId with a worker name in list order. Task description pattern:
`gsd-plan:<plan-id>|<plan-path>|<summary-path>`.

```bash
PLAN_IDS=($(echo "$PLANS_IN_WAVE"))
WORKERS=($(echo "$WORKER_NAMES"))
TASK_IDS=()

for i in "${!PLAN_IDS[@]}"; do
  PID="${PLAN_IDS[$i]}"
  WNAME="${WORKERS[$i]:-}"
  [ -z "$WNAME" ] && { echo "✗ no worker slot for plan $PID" >&2; exit 1; }

  PLAN_PATH="$PHASE_DIR/${PID}-PLAN.md"
  [ -f "$PLAN_PATH" ] || PLAN_PATH="$PHASE_DIR/PLAN.md"
  SUMMARY_PATH="$PHASE_DIR/${PID}-SUMMARY.md"

  DESC="gsd-plan:${PID}|${PLAN_PATH}|${SUMMARY_PATH}"
  SUBJ="plan ${PID}"

  RESP=$(omc team api create-task --input "$(jq -nc \
    --arg tn "$TEAM" --arg s "$SUBJ" --arg d "$DESC" --arg o "$WNAME" \
    '{team_name:$tn, subject:$s, description:$d, owner:$o}')" --json)
  TID=$(jq -r .task.task_id <<<"$RESP")
  [ -z "$TID" ] || [ "$TID" = "null" ] && { echo "✗ create-task failed: $RESP" >&2; exit 1; }
  TASK_IDS+=("$TID")
  echo "  task $TID → worker $WNAME → $PID"
done

# Persist for audit/resume
printf '%s\n' "${TASK_IDS[@]}" > "$OMC_DIR/wave-$WAVE_KEY.tasks"
```

### 3d. Poll until wave drains

```bash
TEAM=$(cat "$OMC_DIR/team.txt")
DONE=0; FAIL=0
TOTAL="$COUNT"
TIMEOUT_SECS=1800      # 30 min wave budget; surfaces a stuck wave
ELAPSED=0; INTERVAL=15

while [ "$ELAPSED" -lt "$TIMEOUT_SECS" ]; do
  LIST=$(omc team api list-tasks --input "{\"team_name\":\"$TEAM\"}" --json)
  # Count only tasks from this wave's TASK_IDS
  DONE=0; FAIL=0; OPEN=0
  while read -r tid; do
    [ -z "$tid" ] && continue
    ST=$(jq -r --arg t "$tid" '.tasks[] | select(.task_id==$t) | .status' <<<"$LIST")
    case "$ST" in
      completed) DONE=$((DONE+1));;
      failed)    FAIL=$((FAIL+1));;
      *)         OPEN=$((OPEN+1));;
    esac
  done < "$OMC_DIR/wave-$WAVE_KEY.tasks"

  FRAC=$(awk "BEGIN{print ($DONE+$FAIL)/$TOTAL}")
  cmux set-progress "$FRAC" --label "wave $WAVE_KEY: $DONE/$TOTAL done, $FAIL failed"

  [ "$OPEN" -eq 0 ] && break
  sleep "$INTERVAL"; ELAPSED=$((ELAPSED+INTERVAL))
done

[ "$OPEN" -eq 0 ] || { echo "✗ wave $WAVE_KEY timed out — $OPEN tasks still open" >&2; exit 1; }
[ "$FAIL" -eq 0 ] || { echo "✗ wave $WAVE_KEY: $FAIL tasks failed — stop, do not advance" >&2; exit 1; }
```

### 3e. Gate — verify SUMMARY.md artifacts

```bash
for PID in $PLANS_IN_WAVE; do
  SP="$PHASE_DIR/${PID}-SUMMARY.md"
  [ -s "$SP" ] || { echo "✗ missing/empty $SP" >&2; exit 1; }
done
cmux log --source gsd-orch --level success "wave $WAVE_KEY complete"
```

Advance to next wave; else proceed to Step 4.

## Step 4 — Aggregate phase SUMMARY.md

```bash
PHASE_SUMMARY="$PHASE_DIR/SUMMARY.md"
{
  echo "# SUMMARY — phase $PHASE"
  echo
  echo "**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "**Team:** $(cat "$OMC_DIR/team.txt")"
  echo
  for WAVE_KEY in $(jq -r '.waves | keys | .[]' <<<"$INDEX_JSON" | sort -n); do
    echo "## Wave $WAVE_KEY"
    echo
    for PID in $(jq -r --arg w "$WAVE_KEY" '.waves[$w][]' <<<"$INDEX_JSON"); do
      echo "### Plan $PID"
      echo
      cat "$PHASE_DIR/${PID}-SUMMARY.md"
      echo
    done
  done
} > "$PHASE_SUMMARY"
cmux notify --title "GSD" --body "phase $PHASE complete"
echo "✓ phase summary → $PHASE_SUMMARY"
```

## Step 5 — Teardown

```bash
TEAM=$(cat "$OMC_DIR/team.txt")
# Shutdown pane workers first
omc team shutdown "$TEAM" 2>/dev/null || true
# Cleanup team state (keeps audit under $OMC_DIR since cleanup removes OMC's own state root)
omc team api cleanup --input "{\"team_name\":\"$TEAM\"}" --json || true
```

Print final status and stop.

---

## Failure handling

- **Any task `failed`** — stop immediately. Do not advance waves. Report the failing plan IDs and instruct the user to inspect the worker pane output + SUMMARY.md before retrying.
- **Wave timeout** — surface the stuck task IDs. The user can `omc team api read-task` for each to see last heartbeat / worker state.
- **Orphan team on SIGINT** — the tmux session persists; run `omc team shutdown <team>` or `/gsd-omc-verify cleanup` to reclaim.

## Non-negotiables (enforced)

1. **You never execute a plan.** You parse, spawn, gate, aggregate. Workers execute.
2. **Spawn before create-task.** Workers need to be named before you can set `owner`.
3. **One task per worker per wave.** Don't queue — the adapter assumes 1:1.
4. **Literal substitution everywhere.** Every `omc team api` call re-reads `"$OMC_DIR/team.txt"` or uses the literal captured at step 2 — no `$TEAM` reliance across Bash tool boundaries.
5. **Do not touch settings.json or hooks.** Out of scope for this command (and this adapter).
