# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, etc.) working on this repository.

## Repository shape

Single-purpose repo. The only real artifact is `setup-gsd-cmux.sh` — a bash installer that wires GSD + cmux + Claude Code together. There is no application code, no test suite, no build step.

## What the script actually does

Read `setup-gsd-cmux.sh` end-to-end before editing. Section banners (`PHASE 0` … `FILE 7`) mark logical units:

- **PHASE 0–2** — checks for `python3`, `git`, `node ≥ 18`, `claude` CLI, cmux binary; offers auto-install where reasonable.
- **PHASE 3** — installs the `using-cmux` skill from GitHub into `~/.claude/skills/using-cmux/`.
- **PHASE 4** — verifies GSD is initialized (`.planning/config.json`) or reachable via `npx get-shit-done-cc@latest`.
- **PHASE 5 + FILEs 1–7** — writes the bridge skill, helper scripts, hooks, GSD config, `CLAUDE.md` block, and the `gsd-auto-cmux.sh` launcher.

The script is idempotent and backs up `settings.json` / `.planning/config.json` before mutating them (keeps last 3 backups).

## Invariants — don't break these

1. **Every cmux call must be gated on `$CMUX_SOCKET_PATH`.** The bridge has to work when Claude runs outside cmux.
2. **Two-tier token budget.** `SKILL.md` ≈ 800 tokens, `ORCHESTRATOR.md` ≈ 600 tokens. If you expand either, update the numbers in the final summary block and in `README.md`.
3. **Config files are merged, never overwritten.** Use the existing Python inline blocks as the pattern — read JSON, `setdefault`, append only missing entries, write back. Preserve user-added hooks and skills.
4. **Orchestrator content only loads for `execute` phase.** It lives under `phase_skills.execute`, not `agent_skills`. Don't collapse the two.
5. **`set -euo pipefail` is on.** Any new command that can legitimately fail (`grep -q`, `cp` of optional files, cmux calls) must be guarded with `|| true` or explicit `if`.
6. **`ask()` prompts block the script.** Don't add new prompts inside auto-run paths; users expect the installer to run unattended once the initial checks pass.

## Style

- Match the existing bash style: `log / ok / warn / err / ask` helpers, lowercase function names, uppercase env-like globals (`CLAUDE_DIR`, `PLANNING_DIR`).
- Heredocs for multi-line file content. Use `'EOF'` (quoted) when the body contains `$…` that must not be expanded at install time — the current script relies on this for the skill files.
- Keep section banners (`# ═══…`) — they are load-bearing for humans skimming the script.

## Testing a change

There is no automated test. After editing:

1. `bash -n setup-gsd-cmux.sh` — syntax check.
2. `shellcheck setup-gsd-cmux.sh` if available.
3. Run the script in a throwaway directory (or a git worktree) and diff the resulting `~/.claude/skills/gsd-cmux-bridge/`, `~/.claude/settings.json`, and `.planning/config.json` against a known-good copy.
4. Re-run the script — it must produce no further changes and must not duplicate hook or skill entries.

## Version bumps

`VERSION="5.0.0"` at the top of the script is the source of truth. Bump it when behavior changes, and mention the change in the commit message. There is no changelog file.

## Out of scope

Don't add:

- A test framework, linter config, or CI unless explicitly requested.
- Language runtimes beyond bash + the Python inline blocks already in use.
- Windows support — cmux is macOS-only.
