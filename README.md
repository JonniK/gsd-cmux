# cc-cmux-gsd-integration

A thin adapter that runs [GSD (Get Shit Done)](https://www.npmjs.com/package/get-shit-done-cc) projects end-to-end on top of [oh-my-claude-sisyphus (OMC)](https://www.npmjs.com/package/oh-my-claude-sisyphus) team orchestration, with parallel `execute-phase` work materialized as visible [cmux](https://cmux.com) panes.

**Project lifecycle in, panes of CLI workers out.** The adapter never re-implements what OMC and GSD already do — it is only the wiring between them.

See [DESIGN.md](DESIGN.md) for how the pieces fit.

## Install

Prereqs on PATH: `omc` (`npm i -g oh-my-claude-sisyphus`), `cmux`, `claude`, `node`, `jq`, `python3`.

```bash
cd your-gsd-project
bash setup-gsd-omc.sh
```

Writes:

| Where                                             | What                                              |
|---------------------------------------------------|---------------------------------------------------|
| `~/.claude/skills/gsd-omc-bridge/SKILL.md`        | Worker lifecycle contract                         |
| `~/.claude/commands/gsd-omc-run.md`               | Full-lifecycle entry point                        |
| `~/.claude/commands/gsd-omc-execute.md`           | Single-phase orchestrator (wave → panes)          |
| `~/.claude/commands/gsd-omc-verify.md`            | End-to-end smoke test                             |
| `.planning/config.json`                           | `agent_skills.gsd-executor += global:gsd-omc-bridge` |

Flags: `--yes` (accept overwrites), `--dry-run` (show actions), `--no-global` (skip `~/.claude`).

Does **not** touch `~/.claude/settings.json` or `~/.claude/hooks/` — OMC and GSD own those. `omc doctor conflicts` stays clean.

Re-running is safe — every file write is new/unchanged/differs-with-backup.

## Prerequisite: be inside cmux

Every adapter command hard-aborts with `✗ not inside cmux` when `$CMUX_SOCKET_PATH` is unset. Open a cmux workspace in your project directory first; all the commands below run from the Claude session inside that pane. The workers will appear as sibling panes splitting off of it.

## First run — sanity check

```bash
/gsd-omc-verify
```

This scaffolds a synthetic 1-wave / 2-plan phase (`_verify-phase`), runs it end-to-end, asserts that two worker panes appeared, each claimed its task, wrote a `SUMMARY.md`, and the team tore down cleanly. Passing means your install is wired correctly.

Flags:
- `--keep` — leave `.planning/phases/_verify-phase/` around for inspection
- `--full` — additionally exercise the `/gsd-omc-run phase` wrapper path

## Daily use

### Drive the whole project

```bash
/gsd-omc-run autonomous
```

Iterates the roadmap. For each not-done phase: `/gsd-plan-phase` (inline) → `/gsd-omc-execute` (panes) → `/gsd-verify-phase` (inline). Stops on the first verification failure. State persisted to `.planning/.omc/run.json`.

### Start a fresh milestone

```bash
/gsd-omc-run milestone "ship v0.2"
```

Calls `/gsd-new-milestone`, then falls through to `autonomous`.

### Single phase, full cycle

```bash
/gsd-omc-run phase 03-auth
```

Plan-if-needed → execute in panes → verify. Use this when you want one phase done cleanly without touching the rest of the roadmap.

### Just the execute stage

```bash
/gsd-omc-execute 03-auth [--resume] [--max-parallel N]
```

For a phase that is **already planned**. Skips plan/verify; just takes the plan graph, spawns a pane per plan per wave, gates on `completed`, and aggregates `SUMMARY.md`. This is the primitive that `/gsd-omc-run` wraps.

### Resume after an interruption

```bash
/gsd-omc-run resume     # continue from last saved phase/stage
/gsd-omc-run status     # print saved state, do nothing
```

### Clean up leaked teams

```bash
/gsd-omc-run cleanup
```

Walks `.planning/phases/*/.omc/team.txt`, shuts down any still-alive OMC teams, calls `omc team api cleanup`. Always safe to re-run.

## What you should see

Inside your cmux workspace during `/gsd-omc-execute`:

1. Orchestrator logs the preflight summary (phase name, plan count, waves, parallel budget).
2. For each wave, **N new cmux panes split off** your current pane (N = plans in the wave, capped at `--max-parallel`).
3. Each worker pane prints: found my task → claimed → executing plan → writing SUMMARY.md → transitioned to completed.
4. Orchestrator prints `cmux set-progress` lines showing `DONE/TOTAL` as the wave drains.
5. Wave completes → next wave splits fresh panes. Old panes stay for post-mortem until teardown.
6. Final: phase-level `SUMMARY.md` written, `cmux notify` fires, team torn down.

If panes do **not** appear and work seems to happen in a hidden tmux window, see Troubleshooting below.

## Tuning

All knobs are env vars read by `/gsd-omc-execute`:

| Var                       | Default | Effect |
|---------------------------|---------|--------|
| `GSD_OMC_MAX_PARALLEL`    | `3`     | Cap on concurrent worker panes per wave. Overridable per-call with `--max-parallel N`. |
| `GSD_OMC_WAVE_TIMEOUT`    | `1800`  | Seconds before a wave is declared stuck. Bumps useful for long-running plans. |
| `GSD_OMC_POLL_INTERVAL`   | `15`    | Seconds between `list-tasks` polls during a wave. Lower = snappier, higher = quieter. |

Set them in your shell or per invocation:

```bash
GSD_OMC_MAX_PARALLEL=5 /gsd-omc-execute 03-auth
```

## Layout of artifacts

Per phase, after a run:

```
.planning/phases/<phase>/
  *-PLAN.md                  # written by /gsd-plan-phase (unchanged)
  <plan-id>-SUMMARY.md       # one per plan, written by the worker
  SUMMARY.md                 # aggregated by the orchestrator
  VERIFICATION.md            # written by /gsd-verify-phase (unchanged)
  .omc/
    team.txt                 # last team name — used by `cleanup` mode
    wave-<N>.tasks           # task IDs from wave N, for audit / resume
```

Run-level state:

```
.planning/.omc/run.json      # {mode, phase_current, phase_status, phases_done, ...}
```

## Troubleshooting

**Workers run but no panes appear in cmux.** You're likely running an old `~/.claude/commands/gsd-omc-execute.md` that still passes `--new-window` to `omc team`. Re-run `bash setup-gsd-omc.sh --yes` from this repo. (Root cause: `--new-window` makes OMC create a dedicated `omc-<team>` tmux window that cmux does not render as a pane — see invariant #8a in AGENTS.md.)

**Wave hangs / timeout after 30 minutes.** Check a worker pane's scrollback. Most common causes: (a) worker can't find its task — inspect `omc team api list-tasks --input '{"team_name":"<team>"}' --json`; (b) plan references a missing tool; (c) worker is waiting on network. Bump `GSD_OMC_WAVE_TIMEOUT` if the plans genuinely need longer.

**`✗ not inside cmux`.** Open a cmux workspace in the project dir and rerun from the Claude session inside it. The orchestrator needs `$CMUX_SOCKET_PATH` and a real tmux leader pane to split against.

**Team name rejected by OMC.** OMC's regex is `^[a-z0-9][a-z0-9-]{0,29}$` (max 30 chars). The adapter already truncates `gsd-<slug>-<rand>` to fit; if you still hit it, your phase name likely contains unusual chars — rename the phase dir.

**Orphan team after `Ctrl+C`.** `/gsd-omc-run cleanup` walks every `.planning/phases/*/.omc/team.txt` and calls `omc team shutdown` + `omc team api cleanup` on each. Safe to re-run.

**Verify fails at `A.txt != "A"`.** The worker's skill didn't fire. Confirm `~/.claude/skills/gsd-omc-bridge/SKILL.md` exists and `.planning/config.json` has `agent_skills.gsd-executor` containing `global:gsd-omc-bridge`. Re-run `setup-gsd-omc.sh` if either is missing.

## Architecture (1 paragraph)

**GSD** owns what to build (roadmap, phase, plan graph, SUMMARY/VERIFICATION contract). **OMC** owns how to run N CLI workers in parallel (team state, task lifecycle, tmux-via-cmux panes, heartbeats). The adapter is the nervous system: it reads GSD's `phase-plan-index`, pre-assigns each plan to a spawned worker via `owner`, polls for `completed|failed`, and stitches the per-plan SUMMARY.mds into a phase SUMMARY. Nothing more.

See [DESIGN.md](DESIGN.md) for the full architecture.

## Future: Z-mode

v1 reroutes only `execute-phase` to OMC. Planner, verifier, researchers still run as inline Claude Code subagents. A future v2 ("Z-mode") intercepts every Task call so every subagent lands in its own cmux pane. See DESIGN.md §15 for the three candidate implementation paths.

## Uninstall

```bash
rm -rf ~/.claude/skills/gsd-omc-bridge
rm -f ~/.claude/commands/gsd-omc-{run,execute,verify}.md
# Optional: strip "global:gsd-omc-bridge" from .planning/config.json agent_skills.gsd-executor
```

## License

See [LICENSE](LICENSE).
