# DECISION — pivot from custom cmux bridge to thin GSD↔OMC adapter

**Date:** 2026-04-15
**Status:** Accepted
**Owner:** jonnik

## TL;DR

We were building a custom bridge between Claude Code subagents and cmux surfaces from scratch. Discovery of `cmux omc` (Oh My Claude Code, npm package `oh-my-claude-sisyphus`) showed that the **cmux-orchestration layer we were building is already shipped, production, and broader in capability than our v5.4.0 bridge**. We pivot: delete our cmux plumbing, keep only the GSD-specific glue, implement a thin adapter that runs GSD phases on top of OMC's team engine.

## Evidence that drove the pivot

Verified via `omc info`, `omc team --help`, `omc team api --help`, `omc doctor conflicts`:

| Capability we built (or planned) | v5.4.0 location | OMC equivalent |
|---|---|---|
| Spawn N subagents in cmux panes | `gsd-spawn-agent.sh` + `gsd-cmux-orchestrator` SKILL.md | `omc team N:claude:role "task"` (native cmux pane integration via tmux shim) |
| Wait for subagent completion | `gsd-wait-agent.sh` (polls `read-screen` for prompt) | worker heartbeats + `omc team api read-worker-status` |
| Orchestrator↔worker messaging | planned buffers / `wait-for` | `omc team api send-message` / `broadcast` / `mailbox-list` |
| Task board across workers | not yet built | `create-task` / `claim-task` / `transition-task-status` |
| Shutdown protocol | `close-surface` via trap | `write-shutdown-request` / `read-shutdown-ack` |
| Specialized agent roles | 7 agent-types via `agent_skills` injection | 21 roles including `executor`, `verifier`, `planner`, `critic`, `code-reviewer`, `security-reviewer`, `test-engineer`, `debugger`, `architect`, `document-specialist` |
| Autonomous phase loop | GSD's `/gsd-autonomous` | `omc ralphthon` (interview → plan → execute → harden) |
| Supervised research loop | — | `omc autoresearch` (with evaluator contract) |

**`cmux claude-teams`** — not a separate system. Its `--help` returns the stock `claude` CLI help, meaning it is a thin wrapper that launches Claude Code. Not a substitute for team orchestration.

## What OMC does NOT do (the gap we still own)

1. **GSD phase contract** — the artifacts that drive GSD's discipline: `PLAN.md`, `SUMMARY.md`, `VERIFICATION.md`, `RESEARCH.md`, `REVIEW.md`, the phase lifecycle (`discuss → plan → execute → verify`).
2. **Wave-based parallelism derived from `PLAN.md`** — `gsd-tools.cjs phase-plan-index` groups plans by wave; orchestrator spawns one worker per plan per wave, collects `SUMMARY.md` artifacts, gates on wave-complete before next wave. OMC's `team` spawns N workers of one shape for one task — it does not read GSD's plan graph.
3. **GSD slash-command surface** — `/gsd-plan-phase`, `/gsd-execute-phase`, `/gsd-verify-phase`, `/gsd-discuss-phase`, etc. These are the entry points users and their workflow assume.
4. **`agent_skills` injection** — GSD's subagents (`gsd-executor`, `gsd-verifier`, …) need bridge knowledge (cmux-aware logging / notify / status). The v5.4.0 schema fix for `agent_skills` is still correct and still needed.
5. **Hook interop** — OMC's `doctor conflicts` flagged our GSD hooks as `Other` and noted CLAUDE.md has no OMC markers. Real integration needs an `omc setup` pass plus compatibility review.

## Decision

**Scope the project down to a thin GSD↔OMC adapter.** Goal: when a GSD phase executes, each plan in each wave runs as an OMC worker in its own cmux pane, with messages flowing back to the orchestrator's mailbox, and the phase's PLAN/SUMMARY contract enforced end-to-end.

**Keep:**
- `setup-gsd-cmux.sh` FILE 5 logic — `agent_skills` per-agent-type, `global:<name>` refs, legacy migration
- `gsd-cmux-bridge` SKILL.md — context for GSD-native subagents about cmux logging/notify (retain value even when OMC is the spawn mechanism)
- README philosophy: two-tier skill model (bridge is for all GSD agents, adapter layer only for orchestrator)
- AGENTS.md invariants + all v5.4.0 schema lessons
- The five `.claude/projects/.../memory/feedback_*.md` lessons — they apply to future work regardless

**Delete (via `uninstall-gsd-cmux.sh`):**
- `~/.claude/skills/gsd-cmux-orchestrator/` — replaced by OMC
- `~/.claude/scripts/gsd-spawn-agent.sh` — replaced by `omc team`
- `~/.claude/scripts/gsd-wait-agent.sh` — replaced by heartbeats / `read-worker-status`
- `~/.claude/scripts/gsd-cmux-test.sh` — the smoke-test target no longer exists
- `~/.claude/commands/gsd-cmux-test.md` — same
- `~/.claude/settings.json` — strip the two hook commands we added (bridge still works via SKILL.md, hooks were convenience not a contract)
- `CLAUDE.md` marker block — regenerate via OMC's `omc setup` path instead
- `gsd-auto-cmux.sh` launcher — superseded by the adapter entry point (TBD in design doc)
- `/gsd-cmux-test` slash command — superseded by `/gsd-omc-verify` or equivalent (design doc)

**Add (new, in design doc):**
- `setup-gsd-omc.sh` — ensures both `oh-my-claude-sisyphus` and `get-shit-done-cc` installed, runs `omc setup`, writes the GSD↔OMC adapter bridge skill
- `gsd-omc-bridge` skill — teaches `gsd-executor` to (a) translate a wave into `omc team` invocations, (b) exchange messages via `omc team api send-message`, (c) enforce the PLAN/SUMMARY contract via the mailbox
- `/gsd-omc-execute` slash command — wraps `/gsd-execute-phase` with the OMC pipeline
- End-to-end verify command that spawns a real one-wave one-plan phase and round-trips a SUMMARY.md

## Risks & open questions (resolved in design doc)

- Q1: Does OMC's `team` worker have enough freedom to run a GSD plan to completion (full tool access, no artificial caps)?
- Q2: Does `omc team api send-message` support arbitrary payloads (we need to send PLAN.md path + SUMMARY.md path + wave/plan ids)?
- Q3: Hook conflicts — GSD's `gsd-context-monitor.js` (PostToolUse) vs OMC's own hooks. Safe composition or mutual exclusion?
- Q4: Slash-command namespace — does installing OMC install `/omc-*` commands? Do they collide with our `/gsd-omc-*`?
- Q5: Cost — `omc team 3:claude` spins three Claude Code sessions. GSD phases with 8-plan waves become expensive. Knob to serialize under a budget?

## Non-goals (explicit)

- **No custom cmux pane manipulation.** If OMC doesn't already do it, we don't build it.
- **No custom message bus.** Use `omc team api` exclusively for worker↔orchestrator comms.
- **No re-implementation of OMC agent roles.** GSD-specific agent types like `gsd-planner`, `gsd-verifier` remain Claude Code subagents; OMC workers handle the wave-execution role only.
- **No support for pre-OMC usage.** The adapter assumes OMC is installed. Non-OMC GSD users stay on stock GSD without our bridge.

## What happens next

1. **Cleanup (done)** — `uninstall-gsd-cmux.sh` written, dry-run passing.
2. **Design doc** — full architecture of the thin adapter, answering Q1–Q5 with evidence.
3. **Implementation plan** — ordered, testable steps, each with a verification gate.
4. **Implementation** — build, verify, commit atomically.

See: [`DESIGN.md`](DESIGN.md) (to be written next), [`PLAN.md`](PLAN.md) (after design).
