# cc-cmux-gsd-integration

One-shot installer that wires together three tools so Claude Code can drive multi-agent GSD workflows inside cmux:

- **[Claude Code](https://docs.anthropic.com/claude/docs/claude-code)** — Anthropic's CLI coding agent.
- **[cmux](https://cmux.com)** — native macOS terminal with agent/surface orchestration.
- **[GSD (Get Shit Done)](https://www.npmjs.com/package/get-shit-done-cc)** — spec-driven development workflow for Claude Code.

The installer uses a **two-tier skill injection** strategy so the cmux bridge costs only ~800 tokens for most GSD subagents and ~1400 tokens for `gsd-executor` (the execute-phase orchestrator) — down from ~5500 in v1.

Both skills are registered as **global skills** (`global:gsd-cmux-bridge`, `global:gsd-cmux-orchestrator`) in the project's `.planning/config.json` under `agent_skills.<agent-type>`, matching GSD's actual schema.

## Quick start

```bash
cd your-project
./setup-gsd-cmux.sh
```

The script is idempotent — safe to re-run. Existing `settings.json` and `.planning/config.json` are backed up (last 3 copies kept).

## What it checks and installs

| Component | Check | Auto-install |
|---|---|---|
| `python3`, `git` | required | ✗ (errors if missing) |
| Node.js ≥ 18 | required for GSD | optional (via Homebrew) |
| Claude Code CLI | required | optional (via npm) |
| cmux (`/Applications/cmux.app`) | optional | opens cmux.com |
| `using-cmux` skill | `~/.claude/skills/using-cmux/` | clones from GitHub |
| GSD | `.planning/config.json` or npx | runs `npx get-shit-done-cc@latest` |

## What it creates

```
~/.claude/
├── skills/gsd-cmux-bridge/
│   └── SKILL.md              # ~800 tokens — status/progress/notify lifecycle
├── skills/gsd-cmux-orchestrator/
│   └── SKILL.md              # ~600 tokens — wave spawning (gsd-executor only)
├── scripts/
│   ├── gsd-spawn-agent.sh    # spawn subagent in new cmux pane
│   ├── gsd-wait-agent.sh     # poll surface until shell prompt reappears
│   └── gsd-cmux-test.sh      # smoke test — spawn N agents, wait, close
└── settings.json              # +PostToolUse(Task) and Stop hooks

./
├── .planning/config.json      # agent_skills per-agent-type (global: refs)
├── CLAUDE.md                  # <!-- gsd-cmux-bridge --> block
└── gsd-auto-cmux.sh           # launcher for /gsd-autonomous or /gsd-execute-phase
```

## Running a phase

After setup, from a cmux terminal inside the project:

```bash
./gsd-auto-cmux.sh              # run /gsd-autonomous
./gsd-auto-cmux.sh 03           # run /gsd-execute-phase 03
```

The launcher sets workspace/status/progress in cmux, exports `GSD_PROJECT_DIR` and `GSD_START_TIME`, and invokes Claude with `--dangerously-skip-permissions`.

### Slash-command notation auto-detect

GSD ships as either flat skills (`~/.claude/skills/gsd-<name>`, dash notation) or a namespaced plugin (`gsd:<name>`). The launcher detects which at run time:

1. `GSD_CMD_PREFIX` env var (values `gsd-` or `gsd:`) wins.
2. A plugin entry matching `gsd`/`get-shit-done` in `~/.claude/plugins/installed_plugins.json` → `gsd:`.
3. `~/.claude/skills/gsd-autonomous` present → `gsd-`.
4. Fallback: `gsd-`.

If auto-detect picks the wrong one, pin it: `GSD_CMD_PREFIX=gsd: ./gsd-auto-cmux.sh`.

## Verifying the bridge

From a cmux terminal, after install:

```bash
~/.claude/scripts/gsd-cmux-test.sh        # 3 agents (default)
~/.claude/scripts/gsd-cmux-test.sh 5      # 5 agents
```

The test spawns N child surfaces, each child logs via `cmux log`, writes a signal file in a temp dir, then exits. The orchestrator waits for all N signals (30 s timeout), prints what it got, then closes every spawned surface. Exits non-zero if any agent failed to report.

What it proves: `cmux new-split`, `cmux send` (with trailing `\n` as Enter), surface IDs via env vars, `cmux log`/`set-status`/`set-progress`/`notify`, and `cmux close-surface` all work end-to-end. If the test passes, the bridge is wired correctly — a real GSD execute phase will behave the same.

## How the two-tier injection works

GSD reads `agent_skills` as an object keyed by agent-type (`gsd-executor`, `gsd-verifier`, `gsd-planner`, …) and injects each skill into that agent's Task prompt. The installer wires:

| Skill | Injected into |
|---|---|
| `global:gsd-cmux-bridge` (task lifecycle: `set-status`, `set-progress`, `notify`) | `gsd-executor`, `gsd-verifier`, `gsd-planner`, `gsd-phase-researcher`, `gsd-code-reviewer`, `gsd-security-auditor`, `gsd-debugger` |
| `global:gsd-cmux-orchestrator` (wave spawning, buffer data sharing, file-based signals) | `gsd-executor` only |

Both files gate every cmux call on `$CMUX_SOCKET_PATH` being set — so a subagent invoked outside cmux simply skips those calls.

Earlier versions (≤5.3.x) wrote `agent_skills` as a flat array and added a non-existent `phase_skills` key; GSD silently dropped both. v5.4.0 migrates legacy configs in place and removes the stale key on re-run.

## Safety notes

- The launcher uses `claude --dangerously-skip-permissions`. Only run inside trusted project directories.
- `settings.json` and `.planning/config.json` are merged, not overwritten; prior hooks/skills entries are preserved.
- Backups: `<file>.<epoch>.bak` — the three most recent are kept, older ones pruned.

## Requirements

- macOS (cmux is Mac-only; the rest works on Linux but without the cmux surface integration).
- Python 3, git, Node.js 18+.
- An Anthropic API key configured for Claude Code.

## License

MIT — see [LICENSE](LICENSE).
