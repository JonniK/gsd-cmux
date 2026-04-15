# cc-cmux-gsd-integration

One-shot installer that wires together three tools so Claude Code can drive multi-agent GSD workflows inside cmux:

- **[Claude Code](https://docs.anthropic.com/claude/docs/claude-code)** — Anthropic's CLI coding agent.
- **[cmux](https://cmux.com)** — native macOS terminal with agent/surface orchestration.
- **[GSD (Get Shit Done)](https://www.npmjs.com/package/get-shit-done-cc)** — spec-driven development workflow for Claude Code.

The installer uses a **two-tier skill injection** strategy so the cmux bridge costs only ~800 tokens per regular subagent and ~1400 tokens for execute-phase orchestrators (down from ~5500 in v1).

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
│   ├── SKILL.md              # ~800 tokens — injected into ALL subagents
│   └── ORCHESTRATOR.md       # ~600 tokens — added only for execute-phase
├── scripts/
│   ├── gsd-spawn-agent.sh    # spawn subagent in new cmux pane
│   └── gsd-wait-agent.sh     # poll surface until shell prompt reappears
└── settings.json              # +PostToolUse(Task) and Stop hooks

./
├── .planning/config.json      # agent_skills + phase_skills wiring
├── CLAUDE.md                  # <!-- gsd-cmux-bridge --> block
└── gsd-auto-cmux.sh           # launcher for /gsd:auto or /gsd:execute-phase
```

## Running a phase

After setup, from a cmux terminal inside the project:

```bash
./gsd-auto-cmux.sh              # run /gsd:auto
./gsd-auto-cmux.sh 03           # run /gsd:execute-phase 03
```

The launcher sets workspace/status/progress in cmux, exports `GSD_PROJECT_DIR` and `GSD_START_TIME`, and invokes Claude with `--dangerously-skip-permissions`.

## How the two-tier injection works

Every GSD subagent receives `SKILL.md` (task lifecycle: `set-status`, `set-progress`, `notify`). Only agents spawned during the `execute` phase additionally receive `ORCHESTRATOR.md`, which covers wave spawning, buffer-based data sharing, and file-based signals.

Both files gate every cmux call on `$CMUX_SOCKET_PATH` being set — so a subagent invoked outside cmux simply skips those calls.

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
