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

# Binaries first — everything else depends on them.
for c in omc cmux claude node jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "✗ missing binary: $c" >&2; exit 1; }
done

# cmux must be new enough to have the `omc` subcommand (tmux-shim bridge).
# Without it, spawned workers land in a detached omc-team-* tmux session
# that cmux never registers — see Step 3b NOTE.
cmux omc --help >/dev/null 2>&1 || { echo "✗ \`cmux omc\` subcommand missing — update cmux" >&2; exit 1; }

# Multiplexer context detection. Three valid outcomes:
#   cmux        — top-level cmux pane; safe to spawn worker splits here
#   nested-omc  — already inside an omc-team-* tmux session (we're a worker,
#                 not an orchestrator); recursive spawn would be invisible
#   none        — no cmux socket; nothing for workers to register against
#
# The nested-omc check is the one that's saved us: without it, a user who
# runs /gsd-omc-execute from a worker pane gets silently-invisible splits
# that pile up in the parent omc-team session.
if [ -z "${CMUX_SOCKET_PATH:-}" ]; then
  echo "✗ not inside cmux — \$CMUX_SOCKET_PATH unset. Open a cmux workspace in your project and launch claude from the resulting pane." >&2
  exit 1
fi
if [ -n "${TMUX:-}" ]; then
  TMUX_SESSION=$(tmux display-message -p '#S' 2>/dev/null || true)
  case "$TMUX_SESSION" in
    omc-team-*)
      echo "✗ current tmux session is '$TMUX_SESSION' — you appear to be inside an OMC team worker pane, not a top-level cmux workspace." >&2
      echo "  /gsd-omc-execute must be the orchestrator, not a nested worker. Open a fresh cmux pane in your project and retry." >&2
      exit 1
      ;;
  esac
fi

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

OMC 4.11.6 has **no `--team-name` flag**. `omc team` always derives the team
name via `slugifyTask(task)` (cli.cjs ~81798): lowercase → replace non-alnum
runs with `-` → collapse `-+` → trim leading/trailing `-` → slice 30 chars.
We exploit the fact that slugify is the **identity function** on strings of
the form `[a-z0-9][a-z0-9-]{0,28}[a-z0-9]` with no `--` runs and ≤30 chars.
So we pick a valid team name and pass **exactly that string** as the task
argument in Step 3b — OMC then uses it verbatim as the team name.

```bash
# OMC spawn regex:       /^[a-z0-9][a-z0-9-]{0,48}[a-z0-9]$/  (max 50, end alnum)
# OMC create-task regex: /^[a-z0-9][a-z0-9-]{0,29}$/          (max 30, any end)
# Intersection: ≤30 chars, start+end alnum, only [a-z0-9-], no "--".
RAND=$(od -An -N2 -i /dev/urandom | tr -d ' ')
# Budget: "gsd-" (4) + slug + "-" (1) + RAND (up to 5) = room for slug ≤ 20
SLUG=$(echo "$PHASE" \
  | tr '[:upper:]_' '[:lower:]-' \
  | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//' \
  | cut -c1-20 | sed 's/-*$//')
TEAM="gsd-${SLUG}-${RAND}"
# Collapse any accidental "--" and strip trailing "-" after the cut.
TEAM=$(echo "$TEAM" | sed -E 's/-+/-/g; s/-$//' | cut -c1-30 | sed 's/-*$//')

# Invariant: slugifyTask($TEAM) must equal $TEAM, else OMC will pick a
# different name than what we persist to team.txt and every subsequent
# `omc team api` call will fail with "team not found".
if ! [[ "$TEAM" =~ ^[a-z0-9][a-z0-9-]{0,28}[a-z0-9]$ ]] || [[ "$TEAM" == *--* ]]; then
  echo "✗ generated team name '$TEAM' is not slugify-invariant — regenerate" >&2
  exit 1
fi

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

Workers self-identify via `$OMC_TEAM_WORKER` env. OMC names them `worker-1..worker-N` in spawn order. The adapter skill (`global:gsd-omc-bridge`) is registered on the `gsd-executor` agent type via `.planning/config.json` (see `setup-gsd-omc.sh`); the `claude:executor` role spec plus the presence of `$OMC_TEAM_WORKER` in the worker env triggers auto-load of that skill, which drives the full lifecycle (claim → execute → SUMMARY.md → transition).

```bash
cmux log --source gsd-orch --level info "wave $WAVE_KEY: spawning $COUNT panes"
# Cap concurrency — spawn in batches of MAX_PARALLEL; each batch blocks
# until its tasks complete before the next batch begins.
BATCH_SIZE="$MAX_PARALLEL"

# Spawn via `cmux omc team …`, not bare `omc team`.
#
# cmux ships an official bridge (`cmux omc …`) that:
#   1. prepends a private tmux shim to PATH,
#   2. sets fake TMUX / TMUX_PANE pointing at the current cmux surface,
#   3. forwards remaining args to `omc`.
# The shim intercepts OMC's `tmux split-window` calls and rewrites them to
# `cmux new-split`, so worker panes register as native cmux surfaces in the
# current workspace.
#
# Bare `omc team` is a footgun: OMC's detectTeamMultiplexerContext
# (cli.cjs ~27191) checks $TMUX first. If TMUX is unset (common inside
# Claude Code's Bash tool — it only gets CMUX_SURFACE_ID), OMC hits the
# `!inTmux` branch at ~27465 and spawns a DETACHED tmux session named
# `omc-team-<team>-<ts>`. That session is invisible to cmux. Even when
# TMUX is set, the unshimmed `tmux split-window` bypasses cmux's surface
# registry, so the split pane exists but cmux's UI never sees it.
#
# Also: do NOT pass --new-window. Through the shim, --new-window maps to a
# dedicated window we don't want; we want sibling splits off the
# orchestrator pane.
#
# Task argument = $TEAM. OMC uses slugifyTask($TEAM) = $TEAM as the team
# name (see Step 2 invariant) and broadcasts the same string to each
# worker's initial inbox. Workers don't need an elaborate prose bootstrap:
# the `claude:executor` role + the `gsd-omc-bridge` entry in
# .planning/config.json's agent_skills drives skill auto-load, and the
# skill itself starts with `Detect your context` / `OMC_TEAM_WORKER`.
cmux omc team "$COUNT:claude:executor" "$TEAM"
```

Wait ~5s for panes to register, then verify OMC actually created `$TEAM` (if slugify picked a different name we would diverge silently from every API call downstream):

```bash
sleep 5
omc team status "$TEAM" >/dev/null 2>&1 || {
  echo "✗ team '$TEAM' not registered after spawn — slugify divergence or spawn failed" >&2
  # Show what DID get created, for debugging
  ls -d .omc/state/team/*/ 2>/dev/null | tail -5 >&2
  exit 1
}
omc team status "$TEAM"
```

Verify workers are alive. Parse worker names from `omc team api read-config`:

```bash
WORKER_NAMES=$(omc team api read-config --input "{\"team_name\":\"$TEAM\"}" --json \
  | jq -r '.data.workers | sort_by(.index) | .[].name')
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
  TID=$(jq -r .data.task.id <<<"$RESP")
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
TIMEOUT_SECS="${GSD_OMC_WAVE_TIMEOUT:-1800}"      # 30 min wave budget; surfaces a stuck wave
ELAPSED=0; INTERVAL="${GSD_OMC_POLL_INTERVAL:-15}"

while [ "$ELAPSED" -lt "$TIMEOUT_SECS" ]; do
  LIST=$(omc team api list-tasks --input "{\"team_name\":\"$TEAM\"}" --json)
  # Count only tasks from this wave's TASK_IDS
  DONE=0; FAIL=0; OPEN=0
  while read -r tid; do
    [ -z "$tid" ] && continue
    ST=$(jq -r --arg t "$tid" '.data.tasks[] | select(.id==$t) | .status' <<<"$LIST")
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
# Shutdown pane workers first. Use `cmux omc` so the tmux-shim also closes
# the backing cmux surfaces, not just the tmux panes.
cmux omc team shutdown "$TEAM" 2>/dev/null || true
# State cleanup doesn't touch tmux — bare `omc team api` is fine.
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
