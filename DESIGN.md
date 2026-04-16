# DESIGN — thin GSD↔OMC adapter

**Status:** v1

## 1. Goal

**End-to-end goal:** the user opens a cmux workspace, invokes ONE adapter command, and the entire GSD workflow — from `/gsd-new-milestone` or `/gsd-autonomous` through every phase's `plan → execute → verify` cycle — runs to completion with parallel work visible in cmux panes.

**v1 scope (this doc):**

1. A single top-level command `/gsd-omc-run` drives the full lifecycle (new-milestone, autonomous, or phase-scoped) — user picks the entry point, adapter wires everything downstream.
2. Where GSD runs wave-parallel work (`execute-phase`), each plan runs as a visible CLI worker in its own **cmux pane** via OMC.
3. Where GSD runs single-agent work (planner, verifier, researchers, roadmapper, critic) — it stays as inline Claude Code subagents streaming into the orchestrator pane. Still **visible**, just not in a dedicated pane. (See §15 for future Z-mode that moves these to panes too.)
4. Workers **exchange messages** with the orchestrator and with each other via OMC's team API.
5. Each worker's output feeds back into the GSD phase contract — a valid `SUMMARY.md` artifact GSD's verifier can read.
6. The orchestrator **gates wave-to-wave** and **phase-to-phase**, only advancing when prior work is `completed`.
7. At the end, a consolidated milestone-level report is written and all OMC teams are torn down cleanly.

**Mental model:** GSD-Autonomous remains the brain (it decides what phase runs next, what to plan, what to verify). OMC is the muscle (it runs N things in parallel in visible panes). The adapter is the nervous system connecting them — no new decisions, just wiring.

## 2. Why OMC has two team systems (and which we use)

OMC ships two orthogonal orchestration modes:

| Mode | Worker form | Visibility | Inter-worker comms | Used by |
|---|---|---|---|---|
| `/team` (native) | Claude Code `Task` subagents, same session | Inline, streamed into orchestrator context | `SendMessage` tool on the team | `/oh-my-claudecode:team` skill |
| `omc team` CLI | External `claude` / `codex` / `gemini` processes in tmux/cmux panes | Each worker is a separate cmux pane, real-time visible | `omc team api send-message/broadcast/tasks` | `cmux omc team ...` |

**We use `omc team` CLI** because the user-stated goal is *visible work in panes*. `/team` spawns invisible subagents.

**`cmux omc` is the launcher wrapper** that sets up a tmux shim so `omc team`'s tmux splits become native cmux panes.

## 3. Why GSD is not replaced by OMC's `/team` pipeline

Both systems have a `plan → exec → verify → fix` lifecycle. This is not a coincidence — they are solving the same problem. But the artifacts are different:

- **OMC's pipeline** is driven by a synthesized task graph produced by OMC's `planner` agent during `team-plan`.
- **GSD's pipeline** is driven by hand-curated `ROADMAP.md` + `PHASE.md` + `PLAN.md` artifacts in `.planning/` that GSD's own slash commands (`/gsd-new-milestone`, `/gsd-plan-phase`, …) produce.

**Reconciliation principle — separation of concerns:**

| Owns | System |
|---|---|
| Full lifecycle state machine (new-project → new-milestone → discuss → plan → execute → verify → repeat) | GSD |
| What to build (phase spec, PLAN.md structure, wave decomposition) | GSD |
| How to run N workers in parallel in visible panes, coordinate them | OMC |
| What counts as "done" (SUMMARY.md, VERIFICATION.md contract) | GSD |

**The adapter does not fork the lifecycle.** GSD's `/gsd-autonomous` (and `/gsd-new-milestone`, `/gsd-plan-phase`, etc.) continue to drive the state machine. The adapter's single contribution is: where GSD would normally spawn many parallel `Task` subagents (wave-based execution), we reroute that spawn to `cmux omc team` so the work becomes visible panes.

The adapter **skips OMC's `team-plan` / `team-prd` / `team-verify` / `team-fix`** — GSD owns these. It uses only OMC's `team-exec` primitives: `TeamCreate`, `TaskCreate`, worker spawn via `cmux omc team`, `send-message`, heartbeat, `TeamDelete`.

## 4. Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      cmux workspace: GSD: <project>                     │
│  ┌──────────────────────────────┐  ┌─────────────────┐  ┌────────────┐  │
│  │  ORCHESTRATOR pane            │  │  worker-1 pane  │  │ worker-2   │  │
│  │  (Claude Code session)        │  │  claude CLI     │  │ claude CLI │  │
│  │                               │  │  wave-1/plan-1  │  │ wave-1/p-2 │  │
│  │  /gsd-omc-execute foo         │  │                 │  │            │  │
│  │    ├─ reads .planning/…       │  │  runs plan,     │  │  (parallel)│  │
│  │    ├─ `omc team api` calls    │  │  writes         │  │            │  │
│  │    ├─ spawns workers:         │  │  SUMMARY.md,    │  │            │  │
│  │    │   cmux omc team          │  │  sends ACK      │  │            │  │
│  │    │     N:claude:executor    │  │                 │  │            │  │
│  │    ├─ polls tasks             │  │                 │  │            │  │
│  │    └─ writes phase SUMMARY    │  └─────────────────┘  └────────────┘  │
│  └──────────────────────────────┘                                        │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Artifacts read by the adapter

- `.planning/phases/<phase>/PHASE.md` — phase goal + success criteria
- `.planning/phases/<phase>/PLAN.md` — list of plans, each with wave assignment
- `gsd-tools.cjs phase-plan-index` — JSON grouping plans by wave

### 4.2 Artifacts written by the adapter

- `.planning/phases/<phase>/.omc/` — team state dir (team-name, wave progress, message log)
  - `team.json` — OMC team name, wave map
  - `wave-<n>-status.json` — per-wave snapshot for resume
- `.planning/phases/<phase>/plans/<plan-id>/SUMMARY.md` — worker output (GSD-native location, GSD's verifier reads these)
- `.planning/phases/<phase>/SUMMARY.md` — aggregated phase summary (written after final wave)

### 4.3 Identifiers

- OMC team name: `gsd-<slug>-<rand>` (must match `/^[a-z0-9][a-z0-9-]{0,29}$/` — max 30 chars — validated by `omc team api`; slug is truncated to ≤ 20 chars)
- OMC task ids: one per GSD plan. Stored by OMC in `~/.claude/tasks/<team-name>/<n>.json`
- Worker names: `w-<plan-id>` (OMC assigns)

## 5. Orchestrator flow

```
1. Precheck
   • CMUX_SOCKET_PATH set (else: "not inside cmux", abort)
   • omc, cmux, claude on PATH
   • `.planning/phases/<phase>/PLAN.md` exists
   • `omc team api read-config` sanity (requires team_name, so just check omc alive)

2. Parse plan index
   • INDEX = `node "$GSD_ROOT/bin/gsd-tools.cjs" phase-plan-index "$phase"`
   • groups plans by wave

3. Create team
   • TEAM="gsd-<phase>-<rand>"
   • (Workers don't pre-exist — they're created per wave via cmux omc team)
   • Write `.planning/phases/<phase>/.omc/team.json` {team, started_at, waves}

4. For each wave in INDEX.waves:
   a. Spawn workers FIRST (empty team, N panes)
      N=len(wave); budget = min(N, MAX_PARALLEL)     # knob, default 3
      cmux omc team <N>:claude:executor "<BOOTSTRAP_PROMPT>" \
        --team-name "<TEAM>"
      # MUST go through `cmux omc …`, not bare `omc team`. cmux ships
      # an official bridge subcommand that:
      #   - prepends a private tmux shim to PATH
      #   - sets fake TMUX / TMUX_PANE pointing at the current cmux surface
      #   - forwards remaining args to omc
      # The shim intercepts OMC's `tmux split-window` calls and rewrites
      # them as `cmux new-split`, so workers land as native cmux surfaces
      # in the orchestrator's workspace.
      #
      # Bare `omc team` has two failure modes:
      #   (a) TMUX unset (common from Claude Code's Bash tool): OMC's
      #       detectTeamMultiplexerContext (cli.cjs ~27191) hits the
      #       `!inTmux` branch (~27465) and spawns a detached
      #       `omc-team-<name>-<ts>` tmux session cmux never sees.
      #   (b) TMUX set but no shim: raw `tmux split-window` bypasses
      #       cmux's surface registry — pane exists, UI doesn't see it.
      #
      # Also: still DO NOT pass --new-window. Through the shim, that
      # maps to a dedicated window; we want sibling splits off the
      # orchestrator pane.
      # Worker names are derived by OMC as worker-1..worker-N (assigned to
      # panes in spawn order). Workers self-identify via $OMC_TEAM_WORKER
      # env var = "<TEAM>/<worker-name>".

   b. Create tasks pre-assigned to each worker
      Build worker-name list via `omc team status <TEAM>` → parse worker names.
      For each (plan_i, worker_i) pair:
         omc team api create-task --input '{
           "team_name":"<TEAM>",
           "subject":"<plan-title>",
           "description":"gsd-plan:<plan-id>|<plan-path>|<summary-path>",
           "owner":"<worker-name-i>"
         }' --json
      capture task_ids; write `.planning/phases/<phase>/.omc/wave-<n>.json`

   c. Poll completion
      every 15s:
         statuses = omc team api list-tasks --input '{"team_name":"<TEAM>"}' --json
         break when all tasks for wave in ("completed","failed")
         cmux set-progress (done/total) --label "wave <n>"

   d. Gate
      if any failed → stop, surface failure
      verify each SUMMARY.md exists and is non-empty

5. Aggregate
   • Concatenate plan SUMMARY.md files into phase SUMMARY.md with wave headers
   • cmux notify "GSD phase <phase> done"

6. Teardown
   • omc team api cleanup --input '{"team_name":"<TEAM>"}'
   • Keep `.planning/phases/<phase>/.omc/` for audit
```

## 6. Worker prompt contract

Each `omc team N:claude:executor` worker is launched with a bootstrap prompt (interpolated by the orchestrator — dynamic values as literals, per feedback memory). The prompt is static — worker identity comes from the `$OMC_TEAM_WORKER` env var OMC sets at spawn time (`"<team>/<worker-name>"`).

```
You are a GSD worker. OMC has set these env vars:
   OMC_TEAM_WORKER   = <team>/<your-worker-name>     (e.g. "gsd-phase-5-abc/worker-2")
   OMC_TEAM_NAME     = <team>
   OMC_TEAM_STATE_ROOT = <path to team state>

Tool access: full Claude Code toolchain (--dangerously-skip-permissions set by OMC).

Workflow (follow exactly — skill global:gsd-omc-bridge has full details):

1. Identify yourself:
     TEAM="$OMC_TEAM_NAME"
     ME="${OMC_TEAM_WORKER#*/}"        # strip "<team>/" prefix

2. Wait for your pre-assigned task (owner=$ME), poll every 5s for ≤60s:
     omc team api list-tasks --input "{\"team_name\":\"$TEAM\"}" --json
   Response is wrapped: {ok, operation, data:{tasks:[...]}}. Find the task where
   .data.tasks[].owner == "$ME" and .status == "pending". Task id field is .id.

3. Claim it — save the claim_token (response is .data.claimToken, camelCase):
     RESP=$(omc team api claim-task --input \
       "{\"team_name\":\"$TEAM\",\"task_id\":\"$TID\",\"worker\":\"$ME\"}" --json)
     CLAIM_TOKEN=$(jq -r .data.claimToken <<<"$RESP")
   Claiming sets status to "in_progress".

4. Parse the task description (format "gsd-plan:<plan-id>|<plan-path>|<summary-path>").

5. Read <plan-path> (a PLAN-*.md file under .planning/phases/<phase>/plans/).
   Follow it exactly. Write progress to cmux via `cmux log --source gsd-worker` (optional).

6. Write <summary-path> per SUMMARY.md schema (see skill global:gsd-omc-bridge).

7. Transition the task to completed (requires from, to, AND claim_token):
     omc team api transition-task-status --input \
       "{\"team_name\":\"$TEAM\",\"task_id\":\"$TID\",\"from\":\"in_progress\",\"to\":\"completed\",\"claim_token\":\"$CLAIM_TOKEN\"}" --json

8. If blocked or erroring: send one-line blocker to leader-fixed, then transition to
   "failed" (same claim_token). Do not transition to "completed" without a SUMMARY.md.
```

The worker knows these calls because the `gsd-omc-bridge` skill is loaded via `agent_skills` (`gsd-executor` agent-type, `global:gsd-omc-bridge` ref).

**Valid task states:** `pending | blocked | in_progress | completed | failed`. A newly-created task starts `pending`; claim transitions it to `in_progress`; the worker ends in `completed` or `failed`. "blocked" is reserved for dependency-gated tasks (not used in v1). Use `failed` plus a mailbox message for runtime blockers.

## 7. Messaging patterns

- **worker → orchestrator progress** — `omc team api send-message --input '{"team_name":..., "from_worker":"w-1", "to_worker":"leader-fixed", "body":"progress:<pct>:<what>"}'`. Orchestrator reads via `mailbox-list`.
- **orchestrator → worker unblock** — same tool, reverse direction. Worker drains inbox on each loop iteration.
- **broadcast wave change** — `omc team api broadcast --input '{"team_name":..., "body":"wave-2-starting"}'`.
- **shutdown** — orchestrator writes shutdown requests at end; worker acks then exits.

All payloads are short ASCII strings; large artifacts go via file paths, not message bodies.

## 8. Integration constraints

- **Worker tool freedom** — Yes. `cmux omc team N:claude` launches `claude --dangerously-skip-permissions`. Full tool access, same as orchestrator.
- **Message payload** — `body` is a string. For artifacts: paths, not contents. Up to `~4KB` body size observed in OMC source; we stay well under.
- **Hook conflicts** — OMC ships `UserPromptSubmit` + `SessionStart` hooks under `$CLAUDE_PLUGIN_ROOT/scripts/`. GSD ships similarly named ones under `~/.claude/hooks/`. They coexist as additive. Install OMC via `/plugin install` (plugin scope) not global merge, so OMC hooks live at `~/.claude/plugins/.../hooks/` and don't collide with GSD's `~/.claude/hooks/`. `omc doctor conflicts` must stay clean.
- **Slash-command namespace** — OMC plugin installs under `/oh-my-claudecode:<name>` — no collision with `/gsd-*`. Our new command is `/gsd-omc-execute` (fully qualified; no collision).
- **Cost knob** — Adapter reads env `GSD_OMC_MAX_PARALLEL` (default 3). Waves with more plans than budget spawn in batches. Also exposes `GSD_OMC_WORKER_MODEL` (defaults to OMC's routing — `sonnet` for executor; override for cost tuning).

## 9. Components to build

| # | Name | Kind | Purpose |
|---|---|---|---|
| 1 | `setup-gsd-omc.sh` | installer | Installs `gsd-omc-bridge` skill, wires `agent_skills`, verifies OMC + cmux + GSD present. Idempotent (`write_file` helper). |
| 2 | `skills/gsd-omc-bridge/SKILL.md` | skill content | Teaches `gsd-executor` the worker prompt contract and cmux/omc CLI invariants. |
| 3 | `commands/gsd-omc-execute.md` | slash command | Phase-scoped adapter. Runs the orchestrator flow in §5 for one GSD phase. Pure prompt (no external script); uses Bash tool for `omc` / `cmux` / `node` calls. |
| 4 | `commands/gsd-omc-run.md` | slash command | **Top-level entry point** (see §14). Drives the full lifecycle — `/gsd-autonomous` under the hood, but patches each `execute-phase` call to go through `/gsd-omc-execute`. Supports `new-milestone`, `autonomous`, `resume`. |
| 5 | `commands/gsd-omc-verify.md` | slash command | End-to-end smoke: creates a fake milestone with one 2-plan phase, runs `/gsd-omc-run`, asserts phases advance and SUMMARY.md at each level exists. |
| 6 | `README.md` | docs | Rewritten: what the adapter does, when to use which entry point (`/gsd-omc-run` full vs `/gsd-omc-execute` phase-only). |
| 7 | `AGENTS.md` | docs | Invariants updated: new `agent_skills` ref is `global:gsd-omc-bridge`; previous bridge/orchestrator names deprecated. |

**Shared install-script invariants:**
- `agent_skills` schema: object keyed by agent-type, values are `global:<name>` ref lists (validated by GSD's `init.cjs`).
- `write_file` idempotency helper (new / unchanged / differs+backup).
- Settings-file byte-compare no-op pattern.

## 10. Edge cases and resilience

- **Worker crash** — OMC marks task `stalled` after heartbeat timeout (60s default). Orchestrator either requeues (future) or surfaces failure and aborts wave.
- **Orphaned team on abort** — user Ctrl-C in orchestrator pane. Workers keep running. Mitigation: slash command installs a SIGINT trap that broadcasts `shutdown` + calls `omc team api cleanup`.
- **Team-name collision** — timestamp suffix makes collision astronomical; create-team is atomic at the filesystem level.
- **Resumption** — `.planning/phases/<phase>/.omc/team.json` persists across runs. `/gsd-omc-execute --resume <phase>` reads it, skips completed waves. (Nice-to-have, v1 ships without.)
- **Empty wave** — `phase-plan-index` returns `[]` for a wave → orchestrator skips to next.
- **Phase with zero plans** — error out at precheck with a clear message; no team created.

## 11. Non-goals for v1

- No pane-layout customization beyond what `cmux omc` already does.
- No custom message bus or buffer protocol.
- **No PreToolUse hook interception of GSD's Task calls.** Planner/verifier/researcher/critic stay as inline Claude Code subagents in the orchestrator pane. Rerouting every `Task` call into its own OMC-worker pane is **v2 (Z-mode)** — see §15.
- No replacement of GSD's own planner/verifier — their *logic* stays native. We only reroute `execute-phase` wave spawns to OMC workers.
- No support for running without OMC installed. Setup script aborts if `omc` missing.

## 12. Verification strategy

Adapter is considered done when:

1. `setup-gsd-omc.sh` runs clean on a fresh machine (and twice for idempotency)
2. `/gsd-omc-verify` passes: creates 2-plan single-wave phase, runs, writes two `SUMMARY.md`, aggregated phase SUMMARY exists, team cleaned up
3. Manual: open the cmux workspace during verify — two worker panes visibly appear, log activity, disappear at teardown
4. No regressions in `omc doctor conflicts` (additive, not replacing)

Metrics to log during verify (for tuning):
- Wall-time per wave
- % of messages delivered within one poll cycle
- Worker cold-start time (spawn → first claim)

## 13. Open design questions (to be resolved during implementation)

- **D1**: Should the orchestrator itself be a Claude Code subagent (spawned via GSD's own `/gsd-execute-phase`) or a pure slash command loop? The slash command is simpler and stays in the orchestrator pane. Picking slash command for v1.
- **D2**: Do we inject `gsd-omc-bridge` into `gsd-executor` only, or also `gsd-verifier`? Probably just `gsd-executor` — verifier reads files, doesn't spawn panes.
- **D3**: How to signal wave transitions in cmux — `set-progress` only, or also `trigger-flash` / `notify`? Start minimal: progress + status, add alerts only if user feedback asks.
- **D4**: `/gsd-omc-run` — does it wrap `/gsd-autonomous` and intercept only `execute-phase`, or re-implement the autonomous loop itself? v1 picks the **wrap** approach (§14.2) — smaller surface, rides on GSD's existing lifecycle code.

## 14. Full-lifecycle mode: `/gsd-omc-run`

### 14.1 Why this command exists

`/gsd-omc-execute` handles one phase. Real usage starts earlier — `/gsd-new-milestone`, `/gsd-autonomous`, or a plain `/gsd-plan-phase` → `/gsd-execute-phase` → `/gsd-verify-phase` sequence. Users want to invoke one command and let the adapter drive end-to-end with visible panes during execute stages.

### 14.2 Strategy: wrap, don't replace

`/gsd-omc-run <mode> [args]` where `mode` is:

| Mode | Behavior |
|---|---|
| `autonomous` | Invokes `/gsd-autonomous`. When the autonomous loop reaches an `execute-phase` step, the orchestrator pauses the inline subagent path and drives that phase through `/gsd-omc-execute` instead. Remaining phases of the autonomous run continue normally. |
| `milestone <name>` | Invokes `/gsd-new-milestone <name>`, then autonomous mode on the resulting phases. |
| `phase <name>` | Shortcut = `/gsd-omc-execute <name>`. |
| `resume` | Reads last `.planning/.omc/run.json`, resumes from recorded checkpoint. |

### 14.3 How the "reroute execute-phase" works in v1

The orchestrator slash command is a prompt that runs the flow as a script of Bash / tool calls. It does NOT intercept GSD's own Task-tool calls. Instead it:

1. Inspects GSD state (`.planning/CURRENT_PHASE.md`, roadmap, phase dirs) to know what phase is next.
2. If that phase is not yet planned → invokes `/gsd-plan-phase <name>` (inline subagents — planner runs in the orchestrator pane, visible as streaming output).
3. When the phase IS planned → runs the wave-spawning flow from §5 directly (this is where OMC workers appear as panes).
4. When execute-phase is complete → invokes `/gsd-verify-phase <name>` (inline subagents again).
5. If verify passes → advances to next phase; loop.
6. If verify fails → stops, surfaces failure. User either fixes manually or runs `/gsd-omc-run resume`.

The orchestrator never calls `/gsd-execute-phase` directly — that's the whole point. Everything else (`/gsd-plan-phase`, `/gsd-verify-phase`, `/gsd-discuss-phase`, `/gsd-new-milestone`) runs through normal GSD subagents.

### 14.4 State file

`.planning/.omc/run.json`:

```json
{
  "mode": "autonomous",
  "started_at": "2026-04-15T12:30:00Z",
  "milestone": "m1-mvp",
  "phases_completed": ["01-setup"],
  "phase_current": "02-core-api",
  "phase_status": "executing",
  "team_name": "gsd-02-core-api-8f1c3a",
  "checkpoint": {
    "wave_completed": 1,
    "wave_total": 3
  }
}
```

Resume reads this, restarts from `phase_current` at the appropriate step.

### 14.5 User experience

```
$ cmux omc
# … orchestrator pane, Claude Code starts …
> /gsd-omc-run autonomous

▸ Reading roadmap… milestone m1-mvp has 3 phases.
▸ Phase 01-setup: not yet planned → /gsd-plan-phase 01-setup
  [inline planner subagent streams its work here, visible]
▸ Phase 01-setup planned. Starting OMC-backed execution.
  • Wave 1/2: 3 plans → spawning 3 worker panes …
  [cmux splits the current surface; 3 panes appear]
  • Wave 1/2: ✓ 3/3 done
  • Wave 2/2: 2 plans → spawning 2 worker panes …
  [2 more panes]
  • Wave 2/2: ✓ 2/2 done
▸ /gsd-verify-phase 01-setup
  [inline verifier subagent streams here]
▸ Phase 01-setup: ✓ verified. Advancing.
▸ Phase 02-core-api: …
```

### 14.6 Failure modes

- **Plan phase fails** — surface GSD error, stop. No OMC resource created.
- **Execute wave fails** — `omc team api cleanup` runs; state written to `run.json` with `phase_status: "execute_failed"`; user inspects and either resumes or rolls back.
- **Verify fails** — state written with `phase_status: "verify_failed"`; user decides (fix + resume, or rollback).
- **Adapter crashes mid-flight** — `run.json` + per-phase `.omc/team.json` enable resume. Workers may be orphaned → `/gsd-omc-run cleanup` for explicit teardown of dangling teams.

## 15. Future: Z-mode (full Task interception)

**Goal:** every single GSD subagent invocation — planner, verifier, researcher, critic, code-reviewer, security-auditor, etc. — becomes a visible OMC-worker pane, not just the execute-phase waves.

**Why it's not v1:** Claude Code's `Task` tool has no public interception API. Proper Z-mode requires one of:

1. **PreToolUse hook on `Task`** — hook denies the Task call, spawns a matching `cmux omc team 1:claude:<subagent_type>` worker with the same prompt, polls for the worker's SUMMARY artifact, and synthesizes a fake tool result. Fragile: Claude Code's Task result format is rich (nested tool_uses, token counts, internal telemetry). Reconstructing that from a worker's file output is brittle.
2. **MCP `Task`-shim server** — register an MCP tool that mirrors Task's signature and internally routes to OMC. Cleaner contract but requires Claude Code to prefer the MCP version, and still needs result synthesis.
3. **Fork GSD** — ship a modified GSD where every internal subagent call goes through our adapter. Clean but creates a maintenance fork — GSD updates become our problem.

**Acceptance criteria for Z-mode (when eventually built):**
- Z.1 Every GSD Task call surfaces as a labeled cmux pane (label = `gsd-<agent-type>`).
- Z.2 Orchestrator pane still displays the subagent's final output as if the Task had run normally.
- Z.3 Cost overhead ≤ 20% vs inline subagents (CLI startup, OMC coordination overhead).
- Z.4 Works transparently — no GSD-side changes, no user-facing command differences beyond `/gsd-omc-run`.
- Z.5 Hooks coexist cleanly with OMC's own hooks and GSD's own hooks; `omc doctor conflicts` clean.

**Likely approach when we build Z-mode:** MCP shim (option 2). Lowest fork debt, most stable contract. Will require an RFC / ADR in its own repo before implementation — this doc intentionally does not prescribe it.

