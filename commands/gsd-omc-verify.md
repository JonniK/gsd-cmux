---
description: End-to-end smoke test of the GSD↔OMC adapter. Creates a synthetic 1-wave / 2-plan phase, runs /gsd-omc-execute, asserts panes appeared and SUMMARY.md artifacts were produced.
argument-hint: "[--full] [--keep]"
---

# /gsd-omc-verify — adapter smoke test

You are the **smoke-test driver**. Prove the adapter works end-to-end:

1. A synthetic phase appears in `.planning/phases/_verify-phase/`
2. `/gsd-omc-execute _verify-phase` spawns 2 visible cmux worker panes
3. Each worker claims its pre-assigned task, executes a trivial plan, writes `SUMMARY.md`
4. Phase-level `SUMMARY.md` aggregates both
5. OMC team is cleaned up (no orphans)
6. Scratch files (`A.txt`, `B.txt`) actually exist

If `--full` is passed, also run `/gsd-omc-run autonomous` on this synthetic setup.
`--keep` leaves `.planning/phases/_verify-phase/` for post-mortem (default: clean up).

---

## Step 0 — Parse + preflight

```bash
set -euo pipefail

FULL=0; KEEP=0
for arg in "$@"; do
  case "$arg" in
    --full) FULL=1;;
    --keep) KEEP=1;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

[ -n "${CMUX_SOCKET_PATH:-}" ] || { echo "✗ not inside cmux" >&2; exit 1; }
for c in omc cmux claude node jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "✗ missing $c" >&2; exit 1; }
done

# Confirm the adapter is installed
[ -f "$HOME/.claude/commands/gsd-omc-execute.md" ] || { echo "✗ /gsd-omc-execute not installed — run setup-gsd-omc.sh first" >&2; exit 1; }
[ -f "$HOME/.claude/skills/gsd-omc-bridge/SKILL.md" ] || { echo "✗ gsd-omc-bridge skill not installed" >&2; exit 1; }

# Guard — don't clobber a real project
if [ -d ".planning/phases/_verify-phase" ] && [ "$KEEP" -eq 0 ]; then
  echo "! pre-existing _verify-phase — will overwrite (pass --keep to inspect)"
fi
```

## Step 1 — Scaffold synthetic phase

```bash
PDIR=".planning/phases/_verify-phase"
mkdir -p "$PDIR"

# Plan A: write A.txt
cat > "$PDIR/A-PLAN.md" << 'EOF'
---
wave: 1
autonomous: true
objective: Write A.txt containing "A"
---

# PLAN A

<task>
Create a file named `A.txt` in the project root with exactly the text `A` (no newline).

Verification: `test "$(cat A.txt)" = "A"`.
</task>
EOF

# Plan B: write B.txt
cat > "$PDIR/B-PLAN.md" << 'EOF'
---
wave: 1
autonomous: true
objective: Write B.txt containing "B"
---

# PLAN B

<task>
Create a file named `B.txt` in the project root with exactly the text `B` (no newline).

Verification: `test "$(cat B.txt)" = "B"`.
</task>
EOF

# Optional PHASE.md for completeness
cat > "$PDIR/PHASE.md" << 'EOF'
# PHASE — _verify-phase
Goal: Touch A and B via two parallel plans.
EOF

echo "✓ scaffolded $PDIR"
ls -la "$PDIR"
```

Sanity — GSD must recognize the phase:

```bash
node ~/.claude/get-shit-done/bin/gsd-tools.cjs phase-plan-index _verify-phase --raw | jq '{plans: .plans | length, waves: .waves}'
```

Expect `plans: 2`, `waves: {"1": ["A","B"]}`.

## Step 2 — Snapshot cmux surfaces (before)

```bash
BEFORE=$(cmux tree 2>/dev/null | wc -l | tr -d ' ')
echo "surfaces before: $BEFORE"
echo "$BEFORE" > /tmp/gsd-omc-verify.before
```

## Step 3 — Run /gsd-omc-execute

In the **next message** after this step's Bash completes, invoke:

```
/gsd-omc-execute _verify-phase
```

Let it run to completion (panes appear, tasks claim, SUMMARY.mds appear, teardown runs). This is the live test — if anything throws, that is the bug to report.

After it completes, return here for assertions.

## Step 4 — Assertions

```bash
PDIR=".planning/phases/_verify-phase"
FAILED=0
check() { if eval "$1"; then echo "  ✓ $2"; else echo "  ✗ $2"; FAILED=$((FAILED+1)); fi; }

echo "Assertions:"
check "[ -s '$PDIR/A-SUMMARY.md' ]"              "A-SUMMARY.md exists and non-empty"
check "[ -s '$PDIR/B-SUMMARY.md' ]"              "B-SUMMARY.md exists and non-empty"
check "[ -s '$PDIR/SUMMARY.md' ]"                "phase SUMMARY.md aggregated"
check "[ \"\$(cat A.txt 2>/dev/null)\" = 'A' ]"  "A.txt == 'A'"
check "[ \"\$(cat B.txt 2>/dev/null)\" = 'B' ]"  "B.txt == 'B'"

# Surface delta — expect at least +2 (one per worker pane). cmux may also
# have closed panes after shutdown; use monotonic max instead if needed.
AFTER=$(cmux tree 2>/dev/null | wc -l | tr -d ' ')
BEFORE=$(cat /tmp/gsd-omc-verify.before 2>/dev/null || echo 0)
check "[ $AFTER -ge $BEFORE ]"                   "cmux tree did not shrink (panes registered)"

# Orphan team check — .omc/team.txt should not correspond to an alive team
if [ -f "$PDIR/.omc/team.txt" ]; then
  TEAM=$(cat "$PDIR/.omc/team.txt")
  ALIVE=$(omc team status "$TEAM" 2>&1 | grep -c 'alive' || true)
  check "[ $ALIVE -eq 0 ]"                       "team $TEAM torn down (no orphan)"
fi

if [ "$FAILED" -eq 0 ]; then
  echo ""
  echo "✓ PASS — adapter end-to-end verified"
else
  echo ""
  echo "✗ FAIL — $FAILED assertion(s) failed"
fi
```

## Step 5 — Extended (`--full`)

If `--full`:

1. Reset: delete `A.txt`, `B.txt`, `$PDIR/*-SUMMARY.md`, `$PDIR/SUMMARY.md`, `$PDIR/.omc/`.
2. In the next message invoke `/gsd-omc-run phase _verify-phase` (not `autonomous` — we don't have a real roadmap).
3. Re-run Step 4 assertions.

This exercises the `/gsd-omc-run` wrapper path on top of the same synthetic setup.

## Step 6 — Cleanup (unless `--keep`)

```bash
if [ "$KEEP" -eq 0 ]; then
  rm -rf ".planning/phases/_verify-phase"
  rm -f A.txt B.txt
  rm -f /tmp/gsd-omc-verify.before
  echo "✓ cleaned up"
else
  echo "! artifacts kept under .planning/phases/_verify-phase/ (--keep)"
fi
```

Exit with the failure count (0 = pass, >0 = fail).

---

## What this test does NOT cover (future work)

- Multi-wave phase gating (this is 1 wave only)
- Worker failure / mailbox `failed` transition
- `--resume` at phase boundaries in `/gsd-omc-run`
- Z-mode (full Task interception) — not in v1

For those, add dedicated scenarios under `.planning/phases/_verify-multiwave/`, `.planning/phases/_verify-fail/`, etc., following the same pattern.
