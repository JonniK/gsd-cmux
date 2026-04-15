# cc-cmux-gsd-integration

A thin adapter that runs [GSD (Get Shit Done)](https://www.npmjs.com/package/get-shit-done-cc) projects end-to-end on top of [oh-my-claude-sisyphus (OMC)](https://www.npmjs.com/package/oh-my-claude-sisyphus) team orchestration, with parallel `execute-phase` work materialized as visible [cmux](https://cmux.com) panes.

**Project lifecycle in, panes of CLI workers out.** The adapter never re-implements what OMC and GSD already do — it is only the wiring between them.

See [DECISION.md](DECISION.md) for why this exists (the pivot away from a custom cmux bridge) and [DESIGN.md](DESIGN.md) for how the pieces fit.

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

Does **not** touch `~/.claude/settings.json` or `~/.claude/hooks/` — OMC and GSD own those.

## Use

From inside a cmux workspace in your project directory:

```bash
# Primary — drive the project to completion
/gsd-omc-run autonomous

# Kick off a fresh milestone end-to-end
/gsd-omc-run milestone "ship v0.2"

# Single phase (plan if needed → panes → verify)
/gsd-omc-run phase 03-auth

# Resume from last state
/gsd-omc-run resume

# Just the execute-phase stage for a phase that's already planned
/gsd-omc-execute 03-auth

# Sanity check the adapter
/gsd-omc-verify
```

`/gsd-omc-run autonomous` iterates the roadmap — for each phase, it hands off to `/gsd-plan-phase` (inline subagent), then `/gsd-omc-execute` (cmux panes), then `/gsd-verify-phase` (inline). Stops on first verification failure.

During `execute-phase`, each `PLAN-*.md` in the active wave runs as one OMC worker in its own cmux pane. The workers coordinate via `omc team api` (task claim / status / mailbox) — no custom message bus.

## Architecture (1 paragraph)

**GSD** owns what to build (roadmap, phase, plan graph, SUMMARY/VERIFICATION contract). **OMC** owns how to run N CLI workers in parallel (team state, task lifecycle, tmux-via-cmux panes, heartbeats). The adapter is the nervous system: it reads GSD's `phase-plan-index`, pre-assigns each plan to a spawned worker via `owner`, polls for `completed|failed`, and stitches the per-plan SUMMARY.mds into a phase SUMMARY. Nothing more.

See [DESIGN.md](DESIGN.md) for the full architecture and [PLAN.md](PLAN.md) for the implementation plan.

## Future: Z-mode

v1 reroutes only `execute-phase` to OMC. Planner, verifier, researchers still run as inline Claude Code subagents. A future v2 ("Z-mode") intercepts every Task call so every subagent lands in its own cmux pane. See DESIGN.md §15 for the three candidate implementation paths.

## Uninstall

```bash
bash uninstall-gsd-cmux.sh      # removes v5.x artifacts (legacy bridge)
# For the v6 adapter, manually delete:
rm -rf ~/.claude/skills/gsd-omc-bridge
rm -f ~/.claude/commands/gsd-omc-{run,execute,verify}.md
# and optionally strip global:gsd-omc-bridge from .planning/config.json agent_skills
```

## License

See [LICENSE](LICENSE).
