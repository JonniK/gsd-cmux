# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, etc.) working on this repository.

## Repository shape

This repo is a **thin adapter** between GSD and OMC — it is not an orchestrator, framework, or replacement for either tool. The only runtime artifacts are:

- `setup-gsd-omc.sh` — idempotent installer
- `skills/gsd-omc-bridge/SKILL.md` — worker lifecycle contract (loaded via GSD `agent_skills`)
- `commands/gsd-omc-run.md` — full-lifecycle entry point (`/gsd-omc-run`)
- `commands/gsd-omc-execute.md` — single-phase wave orchestrator (`/gsd-omc-execute`)
- `commands/gsd-omc-verify.md` — end-to-end smoke test (`/gsd-omc-verify`)

See [DESIGN.md](DESIGN.md) for architecture.

## Invariants — do not break these

1. **Target is the thin adapter.** If OMC or GSD already provides something (panes, team API, worker lifecycle, phase-plan graph, Task subagents), the adapter uses it — never re-implements it. "Copy-pasting OMC logic into our commands" is a smell.

2. **`agent_skills` schema.** GSD's `init.cjs` validates `agent_skills` as an **object keyed by agent-type** (e.g. `gsd-executor`), values are arrays of `global:<name>` references. Absolute paths are silently dropped by `validatePath`. There is **no** `phase_skills` key. This invariant survives because it is GSD's contract, not ours.

3. **Literal substitution.** Task subagents and spawned CLI workers run in separate process trees with no env inheritance from the orchestrator's Bash tool calls. When a slash command template references a dynamic value (phase name, team name, worker name), substitute it as a **literal string** at prompt-build time — never assume `$VAR` is visible. (Memory: `feedback_task_subagents_need_literal_substitution`.)

4. **Read the consumer, not the template.** Before writing or merging config shapes (especially `.planning/config.json`), grep GSD's parser (`~/.claude/get-shit-done/bin/lib/init.cjs`) to confirm the shape it actually accepts. Template files can drift. (Memory: `feedback_read_consumer_before_writing_config`.)

5. **Registry probe, never execute.** To check that a package is installed, use `npm view` / `npm list -g` / `--version`. Never "run the tool to see if it exists" — side effects, hangs, background processes. (Memory: `feedback_registry_probe_not_execute`.)

6. **Idempotency infra in v1.** Every file write in `setup-gsd-omc.sh` goes through `write_file` — 3-branch helper (new / unchanged / differs-with-backup). Must be correct on the first rerun, not patched after. (Memory: `feedback_idempotency_infra_before_rerun`.)

7. **`using-X` skill is canonical.** For cmux specifics, read `~/.claude/skills/using-cmux/skills/using-cmux/SKILL.md` before writing `cmux send*` / `new-split` / `send-key` logic. Template files drift; the skill is authoritative. (Memory: `feedback_using_skill_is_canonical_source`.)

8. **OMC team API — real signatures, not guesses.** Verify `omc team api <op> --help` before writing the call. Known traps:
   - `claim-task` returns `.data.claimToken` (camelCase); every `transition-task-status` requires it under `claim_token` (snake_case) in the input.
   - Task states are `pending | blocked | in_progress | completed | failed`. Workers poll for `pending`, not `open`.
   - `create-task` with `owner` pre-assigns to a worker; workers self-identify via `$OMC_TEAM_WORKER` = `<team>/<worker-name>`.
   - Every `omc team api <op> --json` wraps the payload as `{ok, operation, data: {...}}` — jq paths go through `.data.*`. Task id field is `.id`.

8a. **Spawn via `cmux omc team`, not bare `omc team`.** cmux ships an official bridge subcommand (`cmux omc …`) that prepends a private tmux shim to PATH and sets fake `TMUX` / `TMUX_PANE` pointing at the current cmux surface; the shim rewrites OMC's `tmux split-window` calls into `cmux new-split` so workers register as native cmux surfaces. Bare `omc team` has two failure modes: (a) if `$TMUX` is unset in the caller (common inside Claude Code's Bash tool), OMC's `detectTeamMultiplexerContext` (cli.cjs ~27191) falls through to the `!inTmux` branch (~27465) and spawns a detached `omc-team-<name>-<ts>` tmux session cmux never sees; (b) even if `$TMUX` is set, raw `tmux split-window` bypasses cmux's surface registry so the pane exists but is invisible to the UI. Also keep `--new-window` off — even with the shim, that maps to a dedicated window, not sibling splits.

8b. **Detect nested-worker context before spawning.** An orchestrator running inside an `omc-team-*` tmux session is actually a worker, not a top-level cmux pane; recursive `omc team` there produces invisible splits in the parent session. Preflight: if `$TMUX` set and `tmux display-message -p '#S'` matches `omc-team-*`, abort with a pointer to "open a top-level cmux pane". This check lives in `/gsd-omc-execute`, `/gsd-omc-verify`, and all non-cleanup modes of `/gsd-omc-run`.

9. **Never touch `$CLAUDE/hooks/` or `$CLAUDE/settings.json` hooks.** OMC owns its lifecycle hooks; GSD owns its own. This adapter is **slash commands + one skill**, nothing else. `omc doctor conflicts` must stay clean after install.

10. **`/gsd-omc-run` wraps, not intercepts.** Reroutes only the `execute-phase` stage through OMC. Planner / verifier / researcher subagents stay inline. Full Task interception is Z-mode — see DESIGN §15. Do not attempt Z-mode in ordinary patches.

## Verification gate

Any change to `commands/*.md` or `skills/gsd-omc-bridge/SKILL.md` must pass `/gsd-omc-verify` before being considered done. The scaffolded `_verify-phase` exercises: spawn → create-task with `owner` → claim → SUMMARY.md → transition → teardown.

For `--full`, add `/gsd-omc-run phase _verify-phase` to exercise the wrapper.

## File-touching discipline

| Path                                          | When to edit                                              |
|-----------------------------------------------|-----------------------------------------------------------|
| `setup-gsd-omc.sh`                            | New file to install / schema migration                    |
| `skills/gsd-omc-bridge/SKILL.md`              | Worker lifecycle changes only; keep under 900 words       |
| `commands/gsd-omc-execute.md`                 | Wave-orchestration logic                                  |
| `commands/gsd-omc-run.md`                     | Mode logic / state-file schema                            |
| `commands/gsd-omc-verify.md`                  | Add a new regression scenario                             |
| `DESIGN.md`                                   | Architectural changes (keep §1–§3 as the contract)        |

## Before committing

1. Rerun `/gsd-omc-verify` — assertions pass.
2. Self-audit against the memory lessons referenced in the invariants above.
3. Keep commit atomic — never mix adapter code with unrelated repo changes.
