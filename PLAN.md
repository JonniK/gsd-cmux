# PLAN — implementation of thin GSD↔OMC adapter

**Prereqs:** [DECISION.md](DECISION.md), [DESIGN.md](DESIGN.md)
**Contract:** every step ends with a verifiable check. No step is marked complete until its check passes.

## Conventions

- `$REPO = /Users/jonnik/IdeaProjects/cc-cmux-gsd-integration`
- `$CLAUDE = ~/.claude`
- Each step lists: **Do**, **Why**, **Check** (commands that prove it works), **Rollback**.
- "Commit" checkpoints are atomic — after the Check passes.
- All new files use the v5.x `write_file` idempotency helper (ship it in step 2 of setup-gsd-omc.sh).
- Dynamic values substituted as literals in subagent prompts (memory: task subagents don't inherit env).

## Legend

- 🟢 low risk / pure additive
- 🟡 medium — touches existing config files
- 🔴 high — modifies global `~/.claude/` state

---

## Phase A — Clear the decks (🟢)

### A1. Run the uninstaller on the live machine
- **Do:** `bash uninstall-gsd-cmux.sh --dry-run` → review diff → `bash uninstall-gsd-cmux.sh` (answers yes to each prompt intentionally)
- **Why:** ground-truth the starting state before laying new pipes.
- **Check:**
  ```
  ! test -d ~/.claude/skills/gsd-cmux-bridge
  ! test -d ~/.claude/skills/gsd-cmux-orchestrator
  ! test -f ~/.claude/scripts/gsd-spawn-agent.sh
  ! test -f ~/.claude/commands/gsd-cmux-test.md
  # settings.json still valid JSON, no bridge hooks
  python3 -c "import json; j=json.load(open('$CLAUDE/settings.json')); assert all('Subagent done' not in h.get('command','') for e in j.get('hooks',{}).get('PostToolUse',[]) for h in e.get('hooks',[])); print('clean')"
  ```
- **Rollback:** backups kept as `*.bak` next to each edited file.

### A2. Archive v5.4.0 code in-repo (don't delete yet)
- **Do:** `git mv setup-gsd-cmux.sh legacy/setup-gsd-cmux-v5.4.0.sh` (or equivalent non-git move if the repo isn't a git repo — a simple `mkdir legacy && mv setup-gsd-cmux.sh legacy/`). README/AGENTS stay in place but get deprecation headers.
- **Why:** historical reference for agents_skills schema insight + idempotency helper. Deleted in a later cleanup commit once v1 of adapter ships and is proven.
- **Check:** `ls legacy/setup-gsd-cmux-v5.4.0.sh`; `! test -f setup-gsd-cmux.sh` (at repo root).
- **Rollback:** move back.

---

## Phase B — Bridge skill (🟢)

### B1. Create `$REPO/skills/gsd-omc-bridge/SKILL.md`
- **Do:** Author the skill content following the DESIGN §6 worker contract. Include:
  - `cmux` env invariants (`CMUX_SOCKET_PATH`, `CMUX_SURFACE_ID`)
  - `omc team api` commands used: `claim-task`, `transition-task-status`, `send-message`, `mailbox-list`, `read-task`
  - SUMMARY.md schema (sections: What changed / Files / Verification / Caveats)
  - Non-negotiables: never spawn child teams, never exceed 1 claim at a time, always ack shutdown
- **Why:** the single canonical reference for worker behavior; loaded via `agent_skills` so gsd-executor subagents auto-know it.
- **Check:** file exists, frontmatter parses (`name`, `description`, `type: skill`), < 1200 tokens (`wc -w` < 900).
- **Rollback:** `rm skills/gsd-omc-bridge/SKILL.md`.

---

## Phase C — Installer (🟡)

### C1. Write `$REPO/setup-gsd-omc.sh` skeleton
- **Do:** Copy the color helpers + `write_file` idempotency helper from the archived v5.4.0 script. Add `ask`, `err`, `ok`, `log`. Base sections:
  - Header with version, purpose
  - Require: `omc`, `claude`, `cmux`, `node`
  - Preflight: `omc doctor conflicts` must not return a hard error
  - `write_file` with three branches (new / unchanged / differs+backup)
- **Why:** reuse what already works; don't re-derive the idempotency pattern.
- **Check:** `bash -n setup-gsd-omc.sh`; running `bash setup-gsd-omc.sh` on a machine missing `omc` aborts with clear message.
- **Rollback:** none — new file.

### C2. Install `gsd-omc-bridge` skill globally
- **Do:** In setup script, `write_file "$CLAUDE/skills/gsd-omc-bridge/SKILL.md"` reading from `$REPO/skills/gsd-omc-bridge/SKILL.md`.
- **Why:** skill must be at `$CLAUDE/skills/…` for GSD's `global:<name>` resolver to find it.
- **Check:** after install, `test -f $CLAUDE/skills/gsd-omc-bridge/SKILL.md`. Re-run → "unchanged".
- **Rollback:** `rm -rf $CLAUDE/skills/gsd-omc-bridge`.

### C3. Wire `agent_skills` in `.planning/config.json`
- **Do:** Port the FILE 5 Python block from v5.4.0 but:
  - Target agents: `["gsd-executor"]` only (per DESIGN §D2)
  - Ref: `"global:gsd-omc-bridge"`
  - Migrate any leftover `global:gsd-cmux-bridge` / `global:gsd-cmux-orchestrator` refs → drop them
- **Why:** subagents auto-load the bridge skill when invoked by GSD.
- **Check:** `python3 -c "import json; c=json.load(open('.planning/config.json')); assert 'global:gsd-omc-bridge' in c['agent_skills']['gsd-executor']"`. Re-run setup → "unchanged".
- **Rollback:** re-run uninstaller Phase 5 logic with new ref.

### C4. No settings.json hooks (explicit)
- **Do:** Do NOT add PostToolUse / Stop / SessionStart hooks. OMC already owns lifecycle hooks; GSD already owns its own. Our adapter is a slash command + skill only.
- **Why:** avoids the h\ook-conflict class of bugs we had in v5.
- **Check:** `grep -c 'cmux log --source gsd' $CLAUDE/settings.json || true` → 0.
- **Rollback:** n/a.

---

## Phase D — Slash command `/gsd-omc-execute` (🟡)

### D1. Author `$REPO/commands/gsd-omc-execute.md`
- **Do:** Write the slash-command markdown implementing the orchestrator flow (DESIGN §5). Frontmatter:
  ```
  ---
  description: Execute a GSD phase with each plan running as a visible cmux pane worker via OMC.
  argument-hint: "<phase> [--resume]"
  ---
  ```
  Body sections, each with a Bash tool call block:
  1. Precheck (CMUX env, `omc`/`cmux`/`claude` on PATH, `.planning/phases/$ARG/PLAN.md` exists)
  2. Parse plan index via `gsd-tools.cjs phase-plan-index`
  3. Generate team name, persist `.planning/phases/$ARG/.omc/team.json`
  4. For each wave: create tasks, spawn workers with literal team-name substituted, poll, gate
  5. Aggregate SUMMARY.md
  6. Teardown: `omc team api cleanup`
  **Crucial:** every Bash command that interpolates a variable uses the literal-substitution pattern from memory. No reliance on env across tool calls.
- **Why:** this IS the adapter. Slash command > bash script because it has access to Claude Code's own Bash tool with proper workspace context, and can orchestrate interactively.
- **Check:** install to `$CLAUDE/commands/gsd-omc-execute.md` via setup, then `claude -p "/gsd-omc-execute" 2>&1 | grep -q "phase"` (responds to slash command listing).
- **Rollback:** `rm $CLAUDE/commands/gsd-omc-execute.md`.

### D2. Install `/gsd-omc-execute` via setup script
- **Do:** In `setup-gsd-omc.sh`, `write_file "$CLAUDE/commands/gsd-omc-execute.md"` from `$REPO/commands/gsd-omc-execute.md`.
- **Why:** slash command must live in `$CLAUDE/commands/` to be invocable.
- **Check:** file present, re-run setup → "unchanged".
- **Rollback:** `rm`.

---

## Phase E — Super-orchestrator `/gsd-omc-run` (🟡)

### E1. Author `$REPO/commands/gsd-omc-run.md`
- **Do:** Write the slash-command markdown implementing the full-lifecycle wrapper (DESIGN §14). Frontmatter:
  ```
  ---
  description: Drive a GSD project end-to-end with execute-phase waves visible as cmux panes.
  argument-hint: "<mode> [args]  (mode = autonomous | milestone <name> | phase <name> | resume)"
  ---
  ```
  Body sections (one Bash/tool block each):
  1. Parse `<mode>`; dispatch.
  2. For `autonomous` mode:
     a. Load `.planning/.omc/run.json` (create if missing), record start
     b. Loop: read `.planning/CURRENT_PHASE.md` or equivalent GSD state
     c. If current phase not planned → invoke `/gsd-plan-phase <name>` (inline subagent, streams to orchestrator pane)
     d. When planned → invoke `/gsd-omc-execute <name>` (spawns worker panes)
     e. When execute done → invoke `/gsd-verify-phase <name>` (inline subagent)
     f. If verify passes → advance; if fails → surface + stop
     g. Loop until roadmap complete or stop
  3. For `milestone <name>` mode: `/gsd-new-milestone <name>` inline, then autonomous.
  4. For `phase <name>`: pass-through to `/gsd-omc-execute <name>`.
  5. For `resume`: read `.planning/.omc/run.json`, restart from recorded state.
  6. Teardown: final cmux notify, clean up any orphaned teams.
- **Why:** this is the "one command end-to-end" UX the user asked for (see DESIGN §1, §14).
- **Critical:** substitute GSD command invocations as literal strings into each inline tool call — no env inheritance assumed between Bash calls.
- **Check:** command renders in `claude -p` slash list; `--dry-run` mode (no actual spawning) walks the state machine given a stub `.planning/` tree and prints the plan of actions.
- **Rollback:** `rm $CLAUDE/commands/gsd-omc-run.md`.

### E2. Install `/gsd-omc-run` via setup script
- **Do:** `write_file "$CLAUDE/commands/gsd-omc-run.md"` in `setup-gsd-omc.sh`.
- **Check:** file present, re-run → "unchanged".

### E3. State file schema
- **Do:** Define `.planning/.omc/run.json` exactly as DESIGN §14.4. Include JSON Schema as a comment block in `gsd-omc-run.md` so the orchestrator can validate on resume.
- **Check:** Synthetic run.json from DESIGN §14.4 parses and resume mode reads `phase_current` correctly (tested via a dry-run branch).

---

## Phase F — Verify command `/gsd-omc-verify` (🟡)

### F1. Author `$REPO/commands/gsd-omc-verify.md`
- **Do:** End-to-end smoke. Slash command that:
  1. Creates a fake milestone in a throwaway workspace:
     - `.planning/roadmap.md` with a single milestone `_verify-mvp` containing one phase `_verify-phase`
     - `.planning/phases/_verify-phase/PHASE.md` (goal: "touch A and B")
     - `.planning/phases/_verify-phase/PLAN.md` with exactly 2 trivial plans in 1 wave
     - Plans: "write A.txt containing 'A'" / "write B.txt containing 'B'" — plan-scoped subdirs to avoid conflict
  2. Invokes `/gsd-omc-run phase _verify-phase` (scope narrow for fast verification)
  3. Asserts:
     - 2 worker panes appeared (snapshot `cmux list-surfaces` before/after — diff = 2)
     - Each produced `.planning/phases/_verify-phase/plans/<id>/SUMMARY.md` non-empty
     - Phase-level `.planning/phases/_verify-phase/SUMMARY.md` aggregates both
     - `omc team api list-tasks` returns empty for the team (cleaned up)
     - Actual A.txt and B.txt written
  4. Optional extended mode `/gsd-omc-verify --full`: runs `/gsd-omc-run autonomous` instead — verifies full-lifecycle path including a dummy verify stage. Off by default (slower, costs more).
  5. Cleans up `.planning/phases/_verify-phase/`, `.planning/roadmap.md`, `.planning/.omc/`.
  - Exit code: 0 on pass, non-zero + diagnostic on fail.
- **Why:** proof that the adapter works end-to-end in both phase-scoped and (optionally) full-lifecycle modes.
- **Check:** Run `/gsd-omc-verify` in a fresh test workspace. Watch cmux for panes appearing. Expect ✓ PASS banner.
- **Rollback:** `rm`.

### F2. Install `/gsd-omc-verify` via setup script
- **Do:** `write_file` it in.
- **Check:** file present, re-run → "unchanged".

---

## Phase G — Docs (🟢)

### G1. Rewrite `README.md`
- **Do:** Four-section structure:
  - "What this is" — 3-sentence pitch
  - "Install" — `setup-gsd-omc.sh` one-liner + OMC prereq
  - "Use" — primary: `/gsd-omc-run autonomous` (full lifecycle); advanced: `/gsd-omc-execute <phase>` (single phase); `/gsd-omc-verify` sanity check
  - "Architecture" — link to DESIGN.md, note on future Z-mode
- **Why:** README rotted across v5.x. Rewrite fresh, not patch.
- **Check:** `wc -l README.md` < 180 (was 400+ in v5).
- **Rollback:** git revert.

### G2. Rewrite `AGENTS.md`
- **Do:** New invariant list:
  1. Target is the thin adapter in this repo, NOT a re-implementation of OMC or GSD.
  2. `agent_skills` schema (object keyed by agent-type; `global:<name>` refs only). This invariant survives because it is GSD's contract, not ours.
  3. Dynamic values always substituted as literals into subagent/worker/tool-call prompts — no env inheritance across Bash tool calls.
  4. Registry probe, not execute, for package existence checks.
  5. Read the consumer, not the template, before writing config merges.
  6. Never duplicate what OMC already provides (panes, team API, workers).
  7. Never touch `$CLAUDE/hooks/` or `$CLAUDE/settings.json` hooks from this adapter.
  8. `/gsd-omc-run` wraps GSD lifecycle but **does not** intercept GSD Task calls. Only `execute-phase` is rerouted to OMC. Full Task interception is Z-mode (v2) — see DESIGN §15.
- **Check:** file present, referenced from README.

---

## Phase H — Cleanup and close-out (🟡)

### H1. Delete archived v5.4.0 after verify passes
- **Do:** After `/gsd-omc-verify` passes in Phase F, remove `legacy/` directory. Extract the two reusable snippets (`write_file` helper + `agent_skills` merge block) as code comments inline in setup-gsd-omc.sh if not already there.
- **Why:** the archive has served its purpose (schema insight is captured in DESIGN.md §9 and inline in the installer).
- **Check:** `! test -d legacy/`.
- **Rollback:** restore from git.

### H2. Self-audit against memory lessons
- **Do:** Grep the new codebase for each of the five `feedback_*.md` rules and confirm compliance:
  - `feedback_idempotency_infra_before_rerun.md` → `write_file` present and used for every file write ✓
  - `feedback_task_subagents_need_literal_substitution.md` → audit each subagent/tool-call prompt in `/gsd-omc-execute`, `/gsd-omc-run`, and `/gsd-omc-verify`; no `$VAR` references expecting inheritance
  - `feedback_using_skill_is_canonical_source.md` → adapter code uses `using-cmux` SKILL.md conventions (correct flags for `new-split`, `rename-tab`, `send`)
  - `feedback_registry_probe_not_execute.md` → setup checks `omc --version` or `npm list -g oh-my-claude-sisyphus` (registry/local, not `omc something-that-might-hang`)
  - `feedback_read_consumer_before_writing_config.md` → config writes read current shape before merging
- **Why:** explicit gate. Past regressions should not reappear.
- **Check:** checklist filled in COMMIT message for final commit.

### H3. Final commit
- **Do:** Atomic commit with message:
  ```
  feat: pivot to thin GSD↔OMC adapter with full-lifecycle entry point

  Replaces v5.x custom cmux bridge with an adapter that runs GSD projects
  end-to-end on top of oh-my-claude-sisyphus (OMC) team orchestration.
  /gsd-omc-run drives the full lifecycle (new-milestone, autonomous,
  phase, resume). During execute-phase, each plan in each wave runs as
  a visible cmux pane worker, coordinated via OMC's team API. Planner,
  verifier and other single-agent GSD stages stay inline, streaming to
  the orchestrator pane.

  Removed: setup-gsd-cmux.sh and all v5.x artifacts.
  Added: setup-gsd-omc.sh, /gsd-omc-run, /gsd-omc-execute,
         /gsd-omc-verify, gsd-omc-bridge skill.

  Z-mode (full Task interception, every subagent in its own pane) is
  documented in DESIGN.md §15 as a future milestone.

  See DECISION.md, DESIGN.md, PLAN.md.
  ```
- **Check:** `git log -1 --stat` shows only expected file changes.

---

## Risk matrix

| Step | Risk | Mitigation |
|---|---|---|
| A1 | Uninstaller corrupts settings.json | Dry-run first; backups kept |
| C3 | agent_skills merge writes wrong shape | Covered by v5.4.0 schema insight; unit-test with synthetic config.json before running live |
| D1 | Slash command orchestration is fragile (many Bash calls) | `/gsd-omc-verify` is the regression net |
| D1 | Worker prompts reference `$TEAM` expecting env inheritance | Memory rule; enforced in H2 audit |
| E1 | `/gsd-omc-run` loop misreads GSD phase state, advances incorrectly | Before every state transition, re-read `.planning/` from disk. Dry-run mode for state-machine testing. |
| E1 | `/gsd-plan-phase` or `/gsd-verify-phase` invoked inline changes behavior when nested in orchestrator | Test in `--full` verify mode before release; fall back to `phase` mode if autonomous path breaks |
| F1 | Verify creates real team but fails mid-way, leaves orphan | SIGINT trap in orchestrator + `omc team api cleanup` at teardown + explicit `/gsd-omc-run cleanup` subcommand |
| H1 | Delete legacy too early loses insight | Schema insight already captured in DESIGN.md |

## Out of scope (deferred to v2)

- **Z-mode** — full Task interception (see DESIGN §15). The eventual goal; not in v1.
- `--resume` at the wave level inside `/gsd-omc-execute` (v1 only resumes at phase boundaries via `/gsd-omc-run resume`)
- Per-plan retry on failed task
- Heartbeat-based stalled-worker detection in orchestrator (v1 relies on wall-clock poll timeout)
- Cost budget enforcement beyond `GSD_OMC_MAX_PARALLEL`
- Integration with GSD's `/gsd-autonomous` at the subagent-rerouting level (v1 invokes `/gsd-autonomous`-equivalent stages from the adapter but does NOT patch its internals)

---

**Ready to execute Phase A on approval.**
