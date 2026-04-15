---
description: Drive a GSD project end-to-end with execute-phase waves visible as cmux panes. Modes — autonomous | milestone <name> | phase <name> | resume | status.
argument-hint: "<mode> [args]"
---

# /gsd-omc-run — full-lifecycle GSD↔OMC orchestrator

You are the **super-orchestrator** for a GSD project. The user wants one command that drives their project from whatever current state to completion, with `execute-phase` stages materialized as visible cmux panes via OMC.

**Scope of this command (v1, per DESIGN.md §14):**
- Wraps the GSD lifecycle loop (`plan → execute → verify` per phase, phase → phase).
- Reroutes ONLY `execute-phase` through `/gsd-omc-execute` (cmux panes).
- Other stages (plan, verify, research) stay as normal GSD slash commands — inline subagents streaming into this pane.
- Z-mode (full Task interception, every subagent in its own pane) is **not** in v1 — see DESIGN §15.

---

## Modes

| Mode                   | Behavior |
|------------------------|----------|
| `autonomous`           | Iterate current roadmap; for each not-done phase, plan → omc-execute → verify. Stop on first failure. |
| `milestone <name>`     | Run `/gsd-new-milestone <name>` first, then fall into `autonomous`. |
| `phase <name>`         | Single-phase loop: plan if not planned → omc-execute → verify. |
| `resume`               | Read `.planning/.omc/run.json`, continue from `phase_current`. |
| `status`               | Print the saved run state; no actions. |
| `cleanup`              | Shutdown any orphan OMC teams under `.planning/phases/*/.omc/team.txt`. |

---

## Step 0 — Parse mode and preflight

```bash
set -euo pipefail

MODE="${1:-}"
[ -z "$MODE" ] && { cat <<EOF
Usage: /gsd-omc-run <mode> [args]
  autonomous                  — drive the current roadmap to completion
  milestone <name>            — create milestone, then autonomous
  phase <name>                — single phase plan→execute→verify
  resume                      — pick up from last saved state
  status                      — print saved run state
  cleanup                     — shutdown orphan OMC teams
EOF
  exit 2; }

# Must be inside cmux — the whole point is visible panes
[ -n "${CMUX_SOCKET_PATH:-}" ] || { echo "✗ not inside cmux — open a cmux workspace first" >&2; exit 1; }

# Binaries
for c in omc cmux claude node jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "✗ missing $c" >&2; exit 1; }
done

# Run state dir
RUN_DIR=".planning/.omc"
RUN_FILE="$RUN_DIR/run.json"
mkdir -p "$RUN_DIR"
```

## Step 1 — State file schema

`.planning/.omc/run.json`:

```json
{
  "version": 1,
  "mode": "autonomous|milestone|phase|resume",
  "started_at": "2026-04-15T12:00:00Z",
  "updated_at": "2026-04-15T12:10:00Z",
  "milestone": "optional milestone name",
  "phase_current": "phase-name or null",
  "phase_status": "planning|executing|verifying|complete|failed",
  "phases_done": ["phase-a", "phase-b"],
  "last_error": null
}
```

Helper (use this whenever you write state):

```bash
write_state() {
  local field_json="$1"   # jq input: '{phase_current:"x", phase_status:"y"}'
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -f "$RUN_FILE" ]; then
    jq --argjson patch "$field_json" --arg now "$now" \
      '. + $patch + {updated_at:$now}' "$RUN_FILE" > "$RUN_FILE.tmp" && mv "$RUN_FILE.tmp" "$RUN_FILE"
  else
    jq -n --argjson patch "$field_json" --arg now "$now" \
      '{version:1, started_at:$now, updated_at:$now} + $patch' > "$RUN_FILE"
  fi
}
read_state() { [ -f "$RUN_FILE" ] && cat "$RUN_FILE" || echo '{}'; }
```

## Step 2 — Dispatch

### Mode: `status`

```bash
read_state | jq .
exit 0
```

### Mode: `cleanup`

```bash
for TEAM_FILE in .planning/phases/*/.omc/team.txt; do
  [ -f "$TEAM_FILE" ] || continue
  TEAM=$(cat "$TEAM_FILE")
  echo "shutting down $TEAM"
  omc team shutdown "$TEAM" 2>/dev/null || true
  omc team api cleanup --input "{\"team_name\":\"$TEAM\"}" --json 2>/dev/null || true
done
exit 0
```

### Mode: `milestone <name>`

```bash
NAME="${2:?milestone name required}"
write_state "$(jq -nc --arg m "milestone" --arg n "$NAME" '{mode:$m, milestone:$n, phase_status:"starting"}')"
```

Invoke `/gsd-new-milestone "$NAME"` as a **separate slash-command call** (Claude Code will run it). Wait for it to finish — it writes new phases into `.planning/phases/`. Then fall through to `autonomous`.

**Do not try to intercept `/gsd-new-milestone`'s internal Task calls.** Let GSD's planner/researcher run inline as intended.

### Mode: `phase <name>`

Skip the phase iteration loop; go straight to the **per-phase loop** in Step 3 with `PHASE="$2"`.

### Mode: `resume`

```bash
[ -f "$RUN_FILE" ] || { echo "✗ no saved run state" >&2; exit 1; }
PHASE_CURRENT=$(jq -r '.phase_current // empty' "$RUN_FILE")
PHASE_STATUS=$(jq -r '.phase_status // empty' "$RUN_FILE")
echo "resuming at phase=$PHASE_CURRENT status=$PHASE_STATUS"
# Fall into Step 3 with PHASE="$PHASE_CURRENT"; the per-phase loop will
# fast-forward past steps already reflected in disk state.
```

### Mode: `autonomous`

Fall through to Step 3 with no `PHASE` pinned — the loop iterates all incomplete phases.

## Step 3 — Phase loop

Determine the phase list:

```bash
if [ -n "${PHASE:-}" ]; then
  PHASES=("$PHASE")
else
  # All phases in roadmap order; skip those already in phases_done
  mapfile -t ALL < <(node ~/.claude/get-shit-done/bin/gsd-tools.cjs phases list --raw)
  DONE_LIST=$(read_state | jq -r '.phases_done[]? // empty')
  PHASES=()
  for p in "${ALL[@]}"; do
    if ! echo "$DONE_LIST" | grep -qx "$p"; then
      PHASES+=("$p")
    fi
  done
fi

[ "${#PHASES[@]}" -eq 0 ] && { echo "✓ nothing to do — all phases complete"; exit 0; }
echo "queue: ${PHASES[*]}"
```

For each `PHASE_NAME` in `PHASES`, run a **three-stage inline workflow**. Each stage is a separate slash-command call — Claude Code renders its subagents into this orchestrator pane.

### 3a. Plan (if not planned)

```bash
PHASE_DIR=$(ls -d .planning/phases/*"${PHASE_NAME}"* 2>/dev/null | head -1)
[ -d "$PHASE_DIR" ] || { echo "✗ phase dir not found for $PHASE_NAME"; exit 1; }

PLAN_COUNT=$(ls "$PHASE_DIR"/*-PLAN.md "$PHASE_DIR"/PLAN.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$PLAN_COUNT" -eq 0 ]; then
  write_state "$(jq -nc --arg p "$PHASE_NAME" '{phase_current:$p, phase_status:"planning"}')"
  # Delegate to GSD's planner — inline subagent.
  echo "▶ /gsd-plan-phase $PHASE_NAME"
fi
```

After this Bash block prints `▶ /gsd-plan-phase …`, in the **next message** invoke the slash command `/gsd-plan-phase "$PHASE_NAME"` (use the literal phase name from above). Wait for its completion before proceeding to 3b.

### 3b. Execute (panes via /gsd-omc-execute)

```bash
write_state "$(jq -nc --arg p "$PHASE_NAME" '{phase_current:$p, phase_status:"executing"}')"
echo "▶ /gsd-omc-execute $PHASE_NAME"
```

In the next message invoke `/gsd-omc-execute "$PHASE_NAME"` — this spawns the worker panes. Do NOT use `/gsd-execute-phase`; that's GSD's single-agent path. The OMC variant IS the point of this wrapper.

### 3c. Verify

```bash
write_state "$(jq -nc --arg p "$PHASE_NAME" '{phase_current:$p, phase_status:"verifying"}')"
echo "▶ /gsd-verify-phase $PHASE_NAME"
```

In the next message invoke `/gsd-verify-phase "$PHASE_NAME"`. If verify reports a blocking failure, record it and stop the outer loop:

```bash
# After verify returns: check for VERIFICATION.md; or rely on GSD's state.
VERIFY_FILE="$PHASE_DIR/VERIFICATION.md"
if [ ! -s "$VERIFY_FILE" ] || grep -qi '^status:\s*fail' "$VERIFY_FILE"; then
  write_state "$(jq -nc --arg e "verification failed for $PHASE_NAME" '{phase_status:"failed", last_error:$e}')"
  echo "✗ $PHASE_NAME failed verification — stopping"
  exit 1
fi

# Mark phase done and advance
write_state "$(jq -nc --arg p "$PHASE_NAME" '
  {phase_current:null, phase_status:"complete"} +
  {phases_done: ((input_filename | tostring) as $_ | [$p])}')" # (append logic below)
# Proper append:
jq --arg p "$PHASE_NAME" '.phases_done = ((.phases_done // []) + [$p] | unique)' "$RUN_FILE" > "$RUN_FILE.tmp" && mv "$RUN_FILE.tmp" "$RUN_FILE"
```

Loop to next `PHASE_NAME`.

## Step 4 — Wrap up

After the loop completes without failures:

```bash
write_state '{phase_status:"complete", phase_current:null}'
cmux notify --title "GSD" --body "run complete: ${#PHASES[@]} phase(s) done"
echo "✓ run complete"
```

---

## Execution pattern (how you interleave tool calls)

Each Step 3a/3b/3c is a **two-turn pattern** when implemented by you:

1. **Turn N:** Run the Bash block for that step (writes state, prints `▶ /gsd-...`).
2. **Turn N+1:** Issue the slash-command call named in the `▶` line (e.g. `/gsd-omc-execute <phase>`). The user sees it run in this pane.
3. **Turn N+2:** Resume — run the next Bash block to check outcome / advance state.

**Do NOT** try to chain slash commands inside one Bash call — slash commands only fire at the Claude Code runtime level.

## Non-negotiables

1. **Never intercept GSD's Task subagents directly.** v1 wraps at the slash-command level only. Full interception = Z-mode = v2.
2. **Write state after every stage transition.** If the user `^C`s, `resume` must be able to pick up cleanly.
3. **Substitute phase names as literals** into every slash-command call — no `$PHASE_NAME` across tool-call boundaries (memory: task subagents don't inherit env).
4. **No re-implementation of `phases list`, `phase-plan-index`, or roadmap logic.** Call GSD's own tools; they're the authority.
5. **Abort loudly on verify failure.** Do not auto-retry. The user (or a future Z-mode agent) decides whether to re-plan or fix.
6. **cleanup mode is always safe to re-run** — it only touches team.txt-bearing directories and tolerates already-dead teams.
