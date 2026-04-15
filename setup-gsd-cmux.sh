#!/usr/bin/env bash

# GSD + cmux Integration Setup v5
# Full setup: dependencies + two-tier skill injection

set -euo pipefail

VERSION="5.3.1"

usage() {
  cat <<USAGE
GSD + cmux Integration Setup v${VERSION}

Usage: $(basename "$0") [--help]

Sets up GSD (Get Shit Done) and cmux integration for Claude Code.
Run from your project directory.

Options:
  --help    Show this help message
USAGE
  exit 0
}

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}▶${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
# ask() reads from /dev/tty so it still works when stdin is a heredoc
# (write_file pipes content via stdin and then calls ask on conflicts).
ask()  { read -p $'\033[1;33m?\033[0m '"$1"' [y/N] ' -n 1 -r </dev/tty; echo; [[ $REPLY =~ ^[Yy]$ ]]; }

# write_file <path> <desc>  (content on stdin)
#   - missing file  → write
#   - identical     → no-op, log "(unchanged)"
#   - differs       → warn + ask; on yes, keep timestamped .bak and overwrite
# Preserves local edits across re-runs.
write_file() {
  local path="$1" desc="$2" tmp
  tmp=$(mktemp)
  cat > "$tmp"

  if [ ! -f "$path" ]; then
    mkdir -p "$(dirname "$path")"
    mv "$tmp" "$path"
    ok "$desc (new)"
    return 0
  fi

  if cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    ok "$desc (unchanged)"
    return 0
  fi

  warn "$desc exists and differs: $path"
  if ask "Overwrite (backup kept)?"; then
    cp "$path" "$path.$(date +%s).bak"
    mv "$tmp" "$path"
    ok "$desc (updated, backup saved)"
  else
    rm -f "$tmp"
    ok "$desc (kept existing)"
  fi
}

CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$CLAUDE_DIR/skills"
GSD_CMUX_SKILL="$SKILLS_DIR/gsd-cmux-bridge"
CMUX_SKILL="$SKILLS_DIR/using-cmux"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
PROJECT_DIR="$PWD"
PLANNING_DIR="$PROJECT_DIR/.planning"
TMP_DIR="${TMPDIR:-/tmp}/gsd-setup-$$"

cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 0: System requirements
# ═══════════════════════════════════════════════════════════════════════════════

log "Checking system requirements"

command -v python3 &>/dev/null || err "python3 required"
ok "python3"

command -v git &>/dev/null || err "git required"
ok "git"

# Node.js (required for GSD)
if command -v node &>/dev/null; then
  NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
  [ "$NODE_VER" -ge 18 ] && ok "node $(node -v)" || warn "node $(node -v) — recommend v18+"
else
  warn "node not found — required for GSD"
  if ask "Install Node.js via Homebrew?"; then
    command -v brew &>/dev/null || err "Homebrew required for auto-install"
    brew install node
    ok "node installed"
  fi
fi

# npm/npx
if command -v npx &>/dev/null; then
  ok "npx"
else
  warn "npx not found"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Claude Code
# ═══════════════════════════════════════════════════════════════════════════════

log "Checking Claude Code"

if command -v claude &>/dev/null; then
  CLAUDE_VER=$(claude --version 2>/dev/null | head -1 || echo "unknown")
  ok "claude CLI ($CLAUDE_VER)"
else
  warn "Claude Code not installed"
  echo ""
  echo "Install via: npm install -g @anthropic-ai/claude-code"
  echo "Or:          brew install claude-code"
  echo ""
  if ask "Install Claude Code via npm?"; then
    npm install -g @anthropic-ai/claude-code
    ok "Claude Code installed"
  else
    warn "Continuing without Claude Code — install manually before running GSD"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: cmux
# ═══════════════════════════════════════════════════════════════════════════════

log "Checking cmux"

CMUX_APP="/Applications/cmux.app"
CMUX_BIN="$CMUX_APP/Contents/Resources/bin/cmux"

if command -v cmux &>/dev/null; then
  ok "cmux (in PATH)"
elif [ -f "$CMUX_BIN" ]; then
  export PATH="${CMUX_BIN%/*}:$PATH"
  ok "cmux ($CMUX_BIN)"
else
  warn "cmux not found"
  echo ""
  echo "cmux is a native macOS terminal with agent orchestration features."
  echo "Download from: https://cmux.com"
  echo ""
  if [[ "$OSTYPE" == "darwin"* ]] && ask "Open cmux.com in browser?"; then
    open "https://cmux.com"
  fi
  warn "Continuing without cmux — install for full integration"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: cmux skill (using-cmux)
# ═══════════════════════════════════════════════════════════════════════════════

log "Checking cmux skill"

if [ -f "$CMUX_SKILL/SKILL.md" ]; then
  ok "using-cmux skill installed"
else
  log "Installing using-cmux skill"
  mkdir -p "$TMP_DIR"

  if git clone --depth 1 https://github.com/hummer98/using-cmux.git "$TMP_DIR/using-cmux" 2>/dev/null; then
    mkdir -p "$CMUX_SKILL"
    cp -r "$TMP_DIR/using-cmux/"* "$CMUX_SKILL/" 2>/dev/null || true

    # Run install script if exists
    if [ -f "$CMUX_SKILL/install.sh" ]; then
      chmod +x "$CMUX_SKILL/install.sh"
      (cd "$CMUX_SKILL" && ./install.sh) || warn "install.sh had issues"
    fi
    ok "using-cmux skill installed"
  else
    warn "Failed to clone using-cmux — check network"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: GSD (Get Shit Done)
# ═══════════════════════════════════════════════════════════════════════════════

log "Checking GSD"

# GSD installs into project via npx, check if .planning exists or package available
GSD_INSTALLED=false

if [ -d "$PLANNING_DIR" ] && [ -f "$PLANNING_DIR/config.json" ]; then
  ok "GSD initialized in project (.planning exists)"
  GSD_INSTALLED=true
elif command -v npm &>/dev/null; then
  # Registry probe only — never execute the package here.
  # `npx get-shit-done-cc@latest --version` can hang: the package may ignore
  # --version and drop into interactive mode, and `npx --yes` only suppresses
  # its own prompts, not the package's stdin reads.
  GSD_VER=$(timeout 10 npm view get-shit-done-cc version 2>/dev/null || true)
  if [ -n "$GSD_VER" ]; then
    ok "GSD available via npx (v$GSD_VER)"
    GSD_INSTALLED=true
  fi
fi

if ! $GSD_INSTALLED; then
  warn "GSD not set up"
  echo ""
  echo "GSD is spec-driven development for Claude Code."
  echo "Initialize with: npx get-shit-done-cc@latest"
  echo "Then run: /gsd-new-project in Claude Code"
  echo ""
  if command -v npx &>/dev/null && ask "Run GSD setup now?"; then
    npx get-shit-done-cc@latest || warn "GSD setup had issues"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: Project validation
# ═══════════════════════════════════════════════════════════════════════════════

log "Validating project"

git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null && ok "git repo" || warn "Not a git repo"

# ── Create directories ────────────────────────────────────────────────────────
mkdir -p "$GSD_CMUX_SKILL" "$SCRIPTS_DIR" "$PLANNING_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 1: Base SKILL.md (~800 tokens) — injected into ALL subagents
# ═══════════════════════════════════════════════════════════════════════════════

log "Writing base SKILL.md"

write_file "$GSD_CMUX_SKILL/SKILL.md" "SKILL.md (~800 tok)" << 'EOF'
# cmux Bridge

Skip ALL cmux calls if `$CMUX_SOCKET_PATH` is unset.

## Task lifecycle

```bash
# Start — icons are NAMED (sparkle, hammer), not emoji
[ -n "$CMUX_SOCKET_PATH" ] && cmux set-status gsd-task "${GSD_TASK_NAME:-task}" --icon sparkle && cmux set-progress 0.05 --label "Starting"

# Progress: update proportionally (step / total_steps)
# Example for 5-step task: 0.2 → 0.4 → 0.6 → 0.8 → 1.0
[ -n "$CMUX_SOCKET_PATH" ] && cmux set-progress 0.4 --label "Writing auth.ts"

# Complete
[ -n "$CMUX_SOCKET_PATH" ] && cmux set-progress 1.0 --label "Done" && cmux notify --title "GSD ✓" --body "Task complete"
```

## Rules

- Never target surfaces you didn't create.
- Prefer env refs: `$CMUX_SURFACE_ID` / `$CMUX_WORKSPACE_ID` are auto-set. Pass `--surface` / `--workspace` explicitly when targeting a spawned child.
- Single-line `send`: a trailing `\n` works as Enter. Multi-line content needs `cmux send-key <surface> return` between lines.
- Save before close: `cmux read-screen --surface $S --scrollback`.
EOF

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 2: ORCHESTRATOR.md (~600 tokens) — only for execute-phase
# ═══════════════════════════════════════════════════════════════════════════════

log "Writing ORCHESTRATOR.md"

write_file "$GSD_CMUX_SKILL/ORCHESTRATOR.md" "ORCHESTRATOR.md (~600 tok)" << 'EOF'
# cmux Orchestrator

Extends base SKILL.md for execute-phase wave management.

## Wave execution

```bash
# Orchestrator's own surface is already in env — never close it
ORCH="${CMUX_SURFACE_ID:?not inside cmux}"

# Spawn via helpers
S1=$(~/.claude/scripts/gsd-spawn-agent.sh ".planning/phases/01/PLAN.md" "auth" "right")
S2=$(~/.claude/scripts/gsd-spawn-agent.sh ".planning/phases/02/PLAN.md" "users" "down")
cmux set-progress 0.1 --label "Wave running"

# Wait
~/.claude/scripts/gsd-wait-agent.sh "$S1" "auth"
~/.claude/scripts/gsd-wait-agent.sh "$S2" "users"

# Capture & cleanup
cmux read-screen --surface "$S1" --scrollback > .planning/output-auth.txt
cmux close-surface --surface "$S1"
cmux close-surface --surface "$S2"
```

## Data sharing

```bash
cmux set-buffer --name "result" "$(cat summary.md)"  # store
cmux paste-buffer --name "result" --surface "$S"     # retrieve
```

## Signals (file-based)

```bash
# No built-in signal commands — use temp files
SIGNAL_DIR="${TMPDIR:-/tmp}/gsd-signals-$$"
mkdir -p "$SIGNAL_DIR"
touch "$SIGNAL_DIR/phase1-done"                                    # send

# wait (poll for file)
while [ ! -f "$SIGNAL_DIR/phase1-done" ]; do sleep 2; done         # receive
rm -rf "$SIGNAL_DIR"                                                # cleanup
```
EOF

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 3: Helper scripts
# ═══════════════════════════════════════════════════════════════════════════════

log "Writing helper scripts"

write_file "$SCRIPTS_DIR/gsd-spawn-agent.sh" "gsd-spawn-agent.sh" << 'SPAWN_EOF'
#!/usr/bin/env bash
set -euo pipefail
[ $# -lt 2 ] && { echo "Usage: $0 <plan> <label> [right|down]" >&2; exit 1; }
PLAN="$1"; LABEL="$2"; DIR="${3:-right}"
[ -z "${CMUX_SOCKET_PATH:-}" ] && { echo "CMUX_SOCKET_PATH not set" >&2; exit 1; }

# Orchestrator's surface is in env — no need to call `cmux identify`
ORCH="${CMUX_SURFACE_ID:-}"
[ -z "$ORCH" ] && { echo "CMUX_SURFACE_ID not set — not in a cmux surface" >&2; exit 1; }

# `cmux new-split` is the canonical split command; its stdout is
# "surface surface:N" — take the second field.
S=$(cmux new-split "$DIR" --surface "$ORCH" | awk '{print $2}')
[ -z "$S" ] && { echo "Failed to create split" >&2; exit 1; }

cmux rename-tab --surface "$S" "$LABEL"

# Escape single quotes in paths
SAFE_PWD="${PWD//\'/\'\\\'\'}"
SAFE_PLAN="${PLAN//\'/\'\\\'\'}"
# Trailing \n on a single-line send works as Enter — no separate send-key needed.
cmux send --surface "$S" "cd '${SAFE_PWD}' && claude --dangerously-skip-permissions -p 'Execute: ${SAFE_PLAN}'\n"
echo "$S"
SPAWN_EOF

write_file "$SCRIPTS_DIR/gsd-wait-agent.sh" "gsd-wait-agent.sh" << 'WAIT_EOF'
#!/usr/bin/env bash
set -euo pipefail
[ $# -lt 2 ] && { echo "Usage: $0 <surface> <label> [timeout_secs]" >&2; exit 1; }
S="$1"; LABEL="$2"; TIMEOUT="${3:-600}"
[ -z "${CMUX_SOCKET_PATH:-}" ] && exit 0

INTERVAL=5; ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  OUTPUT=$(cmux read-screen --surface "$S" --lines 5 2>/dev/null || true)
  # Check for shell prompt indicating agent finished
  if echo "$OUTPUT" | grep -qE '^\s*[\$❯>]\s*$'; then
    cmux log --level success --source gsd -- "$LABEL finished" 2>/dev/null || true
    exit 0
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  [ "$INTERVAL" -lt 30 ] && INTERVAL=$((INTERVAL + 5))
done
cmux log --level warning --source gsd -- "$LABEL timed out" 2>/dev/null || true
exit 1
WAIT_EOF

chmod +x "$SCRIPTS_DIR/gsd-spawn-agent.sh" "$SCRIPTS_DIR/gsd-wait-agent.sh" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 4: Claude settings.json hooks
# ═══════════════════════════════════════════════════════════════════════════════

log "Configuring hooks"

SETTINGS="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.$(date +%s).bak" || warn "Failed to backup settings.json"
fi

python3 - "$SETTINGS" << 'PYEOF' || err "Failed to configure hooks"
import json, os, sys

settings_path = sys.argv[1]

cfg = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            cfg = json.load(f)
    except (json.JSONDecodeError, ValueError):
        print(f"Warning: {settings_path} is not valid JSON, starting fresh", file=sys.stderr)
        cfg = {}

cfg.setdefault("hooks", {})

new_hooks = {
    "PostToolUse": [{
        "matcher": "Task",
        "hooks": [{"type": "command", "command": '[ -n "$CMUX_SOCKET_PATH" ] && cmux log --level success --source gsd -- "Subagent done" 2>/dev/null || true'}]
    }],
    "Stop": [{
        "hooks": [{"type": "command", "command": '[ -n "$CMUX_SOCKET_PATH" ] && cmux notify --title "GSD" --body "Session ended" 2>/dev/null || true'}]
    }]
}

for event, entries in new_hooks.items():
    existing = cfg["hooks"].setdefault(event, [])
    existing_cmds = {h.get("command") for e in existing for h in e.get("hooks", [])}
    for entry in entries:
        if entry["hooks"][0]["command"] not in existing_cmds:
            existing.append(entry)

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

ok "settings.json"

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 5: GSD config.json with conditional orchestrator injection
# ═══════════════════════════════════════════════════════════════════════════════

log "Configuring GSD agent_skills"

GSD_CONFIG="$PLANNING_DIR/config.json"
if [ -f "$GSD_CONFIG" ]; then
  cp "$GSD_CONFIG" "$GSD_CONFIG.$(date +%s).bak" || warn "Failed to backup config.json"
fi

python3 - "$GSD_CONFIG" "$GSD_CMUX_SKILL" << 'PYEOF' || err "Failed to configure GSD"
import json, os, sys

config_path = sys.argv[1]
skills_dir = sys.argv[2]

cfg = {}
if os.path.exists(config_path):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except (json.JSONDecodeError, ValueError):
        print(f"Warning: {config_path} is not valid JSON, starting fresh", file=sys.stderr)
        cfg = {}

base_skill = f"{skills_dir}/SKILL.md"
orch_skill = f"{skills_dir}/ORCHESTRATOR.md"

# Base skill for all agents
skills = cfg.setdefault("agent_skills", [])
if base_skill not in skills:
    skills.append(base_skill)

# Orchestrator skill only for execute-phase
# GSD uses phase_skills for phase-specific injection
phase_skills = cfg.setdefault("phase_skills", {})
execute_skills = phase_skills.setdefault("execute", [])
if orch_skill not in execute_skills:
    execute_skills.append(orch_skill)

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

ok "config.json (base + conditional orchestrator)"

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 6: Minimal CLAUDE.md
# ═══════════════════════════════════════════════════════════════════════════════

log "Updating CLAUDE.md"

CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"
MARKER="<!-- gsd-cmux-bridge -->"
BLOCK="$MARKER
## cmux
If \`\$CMUX_SOCKET_PATH\` set → follow \`~/.claude/skills/gsd-cmux-bridge/SKILL.md\`"

if [ -f "$CLAUDE_MD" ]; then
  grep -q "$MARKER" "$CLAUDE_MD" || printf '\n%s\n' "$BLOCK" >> "$CLAUDE_MD"
else
  echo "$BLOCK" > "$CLAUDE_MD"
fi
ok "CLAUDE.md"

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 7: Launcher
# ═══════════════════════════════════════════════════════════════════════════════

log "Writing launcher"

write_file "$PROJECT_DIR/gsd-auto-cmux.sh" "gsd-auto-cmux.sh" << 'LAUNCH_EOF'
#!/usr/bin/env bash
set -euo pipefail
PHASE="${1:-}"
START=$(date +%s)
CMUX_ACTIVE="${CMUX_SOCKET_PATH:+1}"

command -v claude &>/dev/null || { echo "claude CLI not found" >&2; exit 1; }

# Verify GSD is initialized
if [ ! -f ".planning/config.json" ]; then
  echo "GSD not initialized in this project." >&2
  echo "Run: claude → /gsd-new-project → /clear" >&2
  exit 1
fi

if [ -n "$CMUX_ACTIVE" ]; then
  cmux rename-workspace "GSD: $(basename "$PWD")" 2>/dev/null || true
  cmux set-status gsd-project "$(basename "$PWD")" --icon hammer 2>/dev/null || true
  cmux set-progress 0.0 --label "Starting" 2>/dev/null || true
fi

export GSD_PROJECT_DIR="$PWD" GSD_START_TIME="$START"

# Detect slash-command notation:
#   flat skills   → /gsd-<name>   (plain ~/.claude/skills/gsd-* install)
#   plugin ns     → /gsd:<name>   (installed under a "gsd" plugin namespace)
# Override with GSD_CMD_PREFIX=gsd-  or  GSD_CMD_PREFIX=gsd:
if [ -n "${GSD_CMD_PREFIX:-}" ]; then
  PREFIX="$GSD_CMD_PREFIX"
elif grep -qE '"(gsd|get-shit-done)[-@"]' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null; then
  PREFIX="gsd:"
elif [ -d "$HOME/.claude/skills/gsd-autonomous" ]; then
  PREFIX="gsd-"
else
  PREFIX="gsd-"
fi
GSD_EXEC_CMD="/${PREFIX}execute-phase "
GSD_AUTO_CMD="/${PREFIX}autonomous"
echo "Using slash-command prefix: /${PREFIX}…"

# Note: we intentionally do NOT use `-p` (headless/print mode).
# gsd-autonomous and other GSD skills use AskUserQuestion for blockers,
# grey-area acceptance, and validation — those hang forever under -p.
# Interactive mode launches the session with the slash command pre-filled
# and returns when the user exits claude (/exit or Ctrl-D).
# Override with GSD_HEADLESS=1 if you know your phase won't hit any prompts.
CLAUDE_FLAGS=(--dangerously-skip-permissions)
[ "${GSD_HEADLESS:-0}" = "1" ] && CLAUDE_FLAGS+=(-p)

if [ -n "$PHASE" ]; then
  [ -n "$CMUX_ACTIVE" ] && cmux set-status gsd-phase "Phase $PHASE" --icon hammer 2>/dev/null || true
  claude "${CLAUDE_FLAGS[@]}" "${GSD_EXEC_CMD}${PHASE}"
else
  [ -n "$CMUX_ACTIVE" ] && cmux set-status gsd-phase "auto" --icon sparkle 2>/dev/null || true
  claude "${CLAUDE_FLAGS[@]}" "${GSD_AUTO_CMD}"
fi

MINS=$(( ($(date +%s) - START) / 60 ))
if [ -n "$CMUX_ACTIVE" ]; then
  cmux set-progress 1.0 --label "Done (${MINS}m)" 2>/dev/null || true
  cmux notify --title "GSD ✓" --body "Done in ${MINS}m" 2>/dev/null || true
fi
echo "Complete (${MINS}m)"
LAUNCH_EOF

chmod +x "$PROJECT_DIR/gsd-auto-cmux.sh" 2>/dev/null || true

# ── Backup rotation ──────────────────────────────────────────────────────────
# Keep only the 3 most recent backups per config file
for base_file in "$SETTINGS" "$GSD_CONFIG"; do
  if [ -f "$base_file" ]; then
    # shellcheck disable=SC2012
    ls -t "${base_file}".*.bak 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

CMUX_SKILL_OK=false
[ -f "$CMUX_SKILL/SKILL.md" ] && CMUX_SKILL_OK=true

echo ""
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Setup complete!${NC}"
echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Dependencies:${NC}"
command -v node &>/dev/null && echo -e "  ${GREEN}✓${NC} Node.js $(node -v)" || echo -e "  ${YELLOW}!${NC} Node.js (install for GSD)"
command -v claude &>/dev/null && echo -e "  ${GREEN}✓${NC} Claude Code" || echo -e "  ${YELLOW}!${NC} Claude Code"
{ [ -f "$CMUX_BIN" ] || command -v cmux &>/dev/null; } && echo -e "  ${GREEN}✓${NC} cmux" || echo -e "  ${YELLOW}!${NC} cmux (optional)"
$CMUX_SKILL_OK && echo -e "  ${GREEN}✓${NC} using-cmux skill" || echo -e "  ${YELLOW}!${NC} using-cmux skill"
echo ""
echo -e "${BOLD}Files created:${NC}"
echo "  ~/.claude/skills/gsd-cmux-bridge/SKILL.md        (~800 tok)"
echo "  ~/.claude/skills/gsd-cmux-bridge/ORCHESTRATOR.md (~600 tok)"
$CMUX_SKILL_OK && echo "  ~/.claude/skills/using-cmux/                     (cmux skill)" || true
echo "  ~/.claude/scripts/gsd-spawn-agent.sh"
echo "  ~/.claude/scripts/gsd-wait-agent.sh"
echo "  ~/.claude/settings.json                          (hooks)"
echo "  .planning/config.json                            (agent_skills)"
echo "  CLAUDE.md"
echo "  gsd-auto-cmux.sh"
echo ""
echo -e "${BOLD}Context economy:${NC}"
echo "  Regular subagent: ~800 tokens"
echo "  Orchestrator:     ~1400 tokens"
echo "  (vs ~5500 tokens in v1)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Open cmux terminal in project directory"
echo "  2. If new project: claude → /gsd-new-project → /clear"
echo "  3. Run: ./gsd-auto-cmux.sh [phase]"
echo ""
