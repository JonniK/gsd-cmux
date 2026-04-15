#!/usr/bin/env bash

# GSD + cmux Integration Setup v5
# Full setup: dependencies + two-tier skill injection

set -euo pipefail

VERSION="5.4.0"

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
GSD_CMUX_ORCH_SKILL="$SKILLS_DIR/gsd-cmux-orchestrator"
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
mkdir -p "$GSD_CMUX_SKILL" "$GSD_CMUX_ORCH_SKILL" "$SCRIPTS_DIR" "$PLANNING_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 1: Bridge SKILL.md (~800 tokens) — global:gsd-cmux-bridge
# ═══════════════════════════════════════════════════════════════════════════════
# Injected into the GSD agent-types configured in FILE 5 below
# (gsd-executor, gsd-verifier, gsd-planner, gsd-phase-researcher, …).

log "Writing bridge SKILL.md"

write_file "$GSD_CMUX_SKILL/SKILL.md" "gsd-cmux-bridge/SKILL.md (~800 tok)" << 'EOF'
---
name: gsd-cmux-bridge
description: cmux task lifecycle (status/progress/notify) for GSD subagents — safe no-op outside cmux
---
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
# FILE 2: Orchestrator SKILL.md (~600 tokens) — only for gsd-executor
# ═══════════════════════════════════════════════════════════════════════════════
# Lives in its own global skill dir so GSD can reference it as
# `global:gsd-cmux-orchestrator` from `agent_skills.gsd-executor`.
# GSD's agent_skills is keyed per-agent-type (no phase-level scoping),
# so the two-tier split is now: bridge → most agents, orchestrator → executor.

log "Writing orchestrator SKILL.md"

write_file "$GSD_CMUX_ORCH_SKILL/SKILL.md" "gsd-cmux-orchestrator/SKILL.md (~600 tok)" << 'EOF'
---
name: gsd-cmux-orchestrator
description: Wave-spawning extension to gsd-cmux-bridge — for GSD execute-phase orchestrators
---
# cmux Orchestrator

Extends `~/.claude/skills/gsd-cmux-bridge/SKILL.md` for execute-phase wave management.

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

write_file "$SCRIPTS_DIR/gsd-cmux-test.sh" "gsd-cmux-test.sh" << 'TEST_EOF'
#!/usr/bin/env bash
# End-to-end smoke test of the gsd-cmux bridge:
#   1. Spawns N child surfaces (split panes) from the current cmux surface.
#   2. Each child logs via `cmux log`, writes a signal file, then exits.
#   3. Orchestrator waits for all signals, prints them, closes the surfaces.
# Usage: gsd-cmux-test.sh [N]   (default N=3)
set -euo pipefail

[ -z "${CMUX_SOCKET_PATH:-}" ] && { echo "✗ Not inside cmux (CMUX_SOCKET_PATH unset)" >&2; exit 1; }
[ -z "${CMUX_SURFACE_ID:-}" ]  && { echo "✗ CMUX_SURFACE_ID unset — run from a cmux surface" >&2; exit 1; }
command -v cmux &>/dev/null   || { echo "✗ cmux binary not in PATH" >&2; exit 1; }

N="${1:-3}"
[[ "$N" =~ ^[0-9]+$ ]] || { echo "✗ N must be an integer, got: $N" >&2; exit 1; }
[ "$N" -lt 1 ] || [ "$N" -gt 8 ] && { echo "✗ N must be 1..8" >&2; exit 1; }

SIGNAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gsd-cmux-test.XXXXXX")
SURFACES=()
cleanup() {
  for S in "${SURFACES[@]}"; do cmux close-surface --surface "$S" 2>/dev/null || true; done
  rm -rf "$SIGNAL_DIR"
}
trap cleanup EXIT

ORCH="$CMUX_SURFACE_ID"
echo "▶ Spawning $N test agents from $ORCH"
echo "  signals: $SIGNAL_DIR"
cmux set-status gsd-test "Test bridge: $N agents" --icon sparkle 2>/dev/null || true
cmux set-progress 0.1 --label "Spawning" 2>/dev/null || true

for i in $(seq 1 "$N"); do
  [ $((i % 2)) -eq 0 ] && DIR="down" || DIR="right"
  S=$(cmux new-split "$DIR" --surface "$ORCH" | awk '{print $2}')
  [ -z "$S" ] && { echo "✗ Failed to spawn agent $i" >&2; exit 1; }
  SURFACES+=("$S")
  cmux rename-tab --surface "$S" "test-$i" 2>/dev/null || true
  # Child payload. Trailing \n sends Enter; single-quoted CMD so $vars
  # expand in the child shell, not the parent.
  CMD="echo \"agent $i alive in \$CMUX_SURFACE_ID\" && cmux log --level success --source gsd -- 'agent $i ✓' 2>/dev/null; date +%s > '$SIGNAL_DIR/agent-$i.done'; sleep 1; exit"
  cmux send --surface "$S" "${CMD}"$'\n'
  echo "  ✓ spawned agent $i → $S"
done

cmux set-progress 0.5 --label "Waiting" 2>/dev/null || true
echo "▶ Waiting up to 30s for $N signal files…"
DEADLINE=$(( $(date +%s) + 30 ))
count=0
while :; do
  count=$(find "$SIGNAL_DIR" -maxdepth 1 -name 'agent-*.done' -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge "$N" ] && break
  [ "$(date +%s)" -ge "$DEADLINE" ] && break
  sleep 1
done

echo "▶ Received $count/$N signals:"
for f in "$SIGNAL_DIR"/agent-*.done; do
  [ -f "$f" ] || continue
  echo "  $(basename "$f") ts=$(cat "$f")"
done

cmux set-progress 1.0 --label "Done ($count/$N)" 2>/dev/null || true
cmux notify --title "GSD bridge test" --body "$count/$N agents OK" 2>/dev/null || true

if [ "$count" -eq "$N" ]; then
  echo "✓ Bridge test PASSED ($count/$N)"
  exit 0
else
  echo "✗ Bridge test FAILED ($count/$N)" >&2
  exit 1
fi
TEST_EOF

chmod +x "$SCRIPTS_DIR/gsd-spawn-agent.sh" "$SCRIPTS_DIR/gsd-wait-agent.sh" "$SCRIPTS_DIR/gsd-cmux-test.sh" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 4: Claude settings.json hooks
# ═══════════════════════════════════════════════════════════════════════════════

log "Configuring hooks"

SETTINGS="$CLAUDE_DIR/settings.json"

python3 - "$SETTINGS" << 'PYEOF' || err "Failed to configure hooks"
import json, os, sys, time, shutil

settings_path = sys.argv[1]
existed = os.path.exists(settings_path)

original_text = ""
cfg = {}
if existed:
    try:
        with open(settings_path) as f:
            original_text = f.read()
            cfg = json.loads(original_text) if original_text.strip() else {}
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

new_text = json.dumps(cfg, indent=2) + "\n"

if existed and new_text == original_text:
    print("unchanged")
    sys.exit(0)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
if existed:
    shutil.copy2(settings_path, f"{settings_path}.{int(time.time())}.bak")

with open(settings_path, "w") as f:
    f.write(new_text)
print("updated" if existed else "created")
PYEOF

ok "settings.json"

# ═══════════════════════════════════════════════════════════════════════════════
# FILE 5: GSD config.json — agent_skills (per-agent-type, `global:` refs)
# ═══════════════════════════════════════════════════════════════════════════════
# GSD schema (verified in ~/.claude/get-shit-done/bin/lib/init.cjs):
#   - `agent_skills` is an OBJECT keyed by agent-type (e.g. "gsd-executor").
#   - Each value is an array of skill refs.
#   - `global:<name>` resolves to ~/.claude/skills/<name>/SKILL.md.
#   - Non-global paths are resolved against project root; absolute paths are
#     rejected by validatePath and silently dropped.
#   - There is NO `phase_skills` key — phase-level scoping doesn't exist.
# Earlier versions (≤5.3.x) wrote a flat array and a `phase_skills` dict;
# both were silently ignored. This block migrates those legacy shapes.

log "Configuring GSD agent_skills"

GSD_CONFIG="$PLANNING_DIR/config.json"

python3 - "$GSD_CONFIG" << 'PYEOF' || err "Failed to configure GSD"
import json, os, sys, time, shutil

config_path = sys.argv[1]
existed = os.path.exists(config_path)

# Which agent-types get which skills. Keep narrow: only agents that run
# shell commands or are long-running benefit from cmux progress/notify.
BRIDGE = "global:gsd-cmux-bridge"
ORCH   = "global:gsd-cmux-orchestrator"

BRIDGE_AGENTS = [
    "gsd-executor",
    "gsd-verifier",
    "gsd-planner",
    "gsd-phase-researcher",
    "gsd-code-reviewer",
    "gsd-security-auditor",
    "gsd-debugger",
]
# Orchestrator extension: only the agent that actually spawns waves.
ORCH_AGENTS = ["gsd-executor"]

original_text = ""
cfg = {}
if existed:
    try:
        with open(config_path) as f:
            original_text = f.read()
            cfg = json.loads(original_text) if original_text.strip() else {}
    except (json.JSONDecodeError, ValueError):
        print(f"Warning: {config_path} is not valid JSON, starting fresh", file=sys.stderr)
        cfg = {}

# ── Migrate legacy shapes ────────────────────────────────────────────────────
# Old: agent_skills as a flat list of absolute paths (ignored by GSD).
existing = cfg.get("agent_skills")
if not isinstance(existing, dict):
    cfg["agent_skills"] = {}

# Old: phase_skills dict — never read by GSD. Drop it.
cfg.pop("phase_skills", None)

# ── Merge skill refs (idempotent, preserves user additions) ──────────────────
def ensure(agent, ref):
    lst = cfg["agent_skills"].get(agent)
    if not isinstance(lst, list):
        lst = [] if lst is None else [lst]
    if ref not in lst:
        lst.append(ref)
    cfg["agent_skills"][agent] = lst

for a in BRIDGE_AGENTS:
    ensure(a, BRIDGE)
for a in ORCH_AGENTS:
    ensure(a, ORCH)

new_text = json.dumps(cfg, indent=2) + "\n"

if existed and new_text == original_text:
    print("unchanged")
    sys.exit(0)

os.makedirs(os.path.dirname(config_path), exist_ok=True)
if existed:
    shutil.copy2(config_path, f"{config_path}.{int(time.time())}.bak")

with open(config_path, "w") as f:
    f.write(new_text)
print("updated" if existed else "created")
PYEOF

ok "config.json (agent_skills wired per-agent-type)"

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
# FILE 6b: Slash command — /gsd-cmux-test
# ═══════════════════════════════════════════════════════════════════════════════
# A user-global Claude Code slash command that exercises the bridge from
# inside a Claude session: parent spawns 3 Task subagents, each subagent
# opens a new cmux surface, says hello, and returns a short JSON report.

log "Writing /gsd-cmux-test slash command"

COMMANDS_DIR="$CLAUDE_DIR/commands"
mkdir -p "$COMMANDS_DIR"

write_file "$COMMANDS_DIR/gsd-cmux-test.md" "/gsd-cmux-test command" << 'CMD_EOF'
---
description: Smoke-test the cmux bridge — spawn 3 subagents that open new cmux surfaces, say hello, report back
argument-hint: "[count]"
---
# cmux Bridge Smoke Test

Run a live end-to-end test of the gsd-cmux bridge. You are the **orchestrator**.

## Preflight (you do this, not the subagents)

1. Check `$CMUX_SOCKET_PATH` and `$CMUX_SURFACE_ID` are set in the current shell (run `echo` via Bash). If either is missing, stop and tell the user: "Not running inside a cmux surface — open a cmux terminal first." Do not proceed.
2. Decide `N` = `$1` if provided and numeric in 1..5, otherwise `3`.
3. Record the orchestrator surface id: `ORCH=$CMUX_SURFACE_ID`.

## Spawn wave

Spawn `N` subagents **in parallel** — a single assistant message with `N` Task tool calls. Use `subagent_type: general-purpose`. Give each agent a unique index `i` (1..N) and the orchestrator surface id.

Each subagent prompt must instruct it to:

1. Verify `$CMUX_SOCKET_PATH` is set (fail loud if not).
2. Split a new surface off the orchestrator:
   ```bash
   DIR=$([ $((i % 2)) -eq 0 ] && echo down || echo right)
   S=$(cmux new-split "$DIR" --surface "$ORCH" | awk '{print $2}')
   ```
   Parse stdout with `awk '{print $2}'` — cmux prints `surface surface:N`.
3. Rename the tab: `cmux rename-tab --surface "$S" "hello-$i"`.
4. Send a hello line (trailing `\n` acts as Enter, no separate `send-key` needed):
   ```bash
   cmux send --surface "$S" $'echo "hello from agent '"$i"' — I am $CMUX_SURFACE_ID"\n'
   ```
5. Log a completion event: `cmux log --level success --source gsd -- "agent $i ready"`.
6. Wait ~1s for the shell to render, then capture the surface output:
   ```bash
   HELLO=$(cmux read-screen --surface "$S" --lines 20 | grep -F "hello from agent $i" | head -1)
   ```
7. Close the child surface: `cmux close-surface --surface "$S"`.
8. Return a single JSON line as the final assistant message: `{"agent": <i>, "surface": "<S>", "hello": "<HELLO line>", "ok": true}`. If any step fails, return `ok: false` with an `error` field.

## Collect + report

After all `N` Task calls return, you (the orchestrator):

1. Parse each subagent's JSON result.
2. Print a compact table (agent | surface | hello-line | ok).
3. Tag the orchestrator surface: `cmux set-status gsd-test "bridge $ok_count/$N" --icon sparkle` (via Bash).
4. State the verdict in one sentence: `PASS` if all `ok=true`, else `FAIL` with which agents failed.

## Rules

- Do **not** target the orchestrator surface with any destructive cmux call. Only operate on surfaces you spawned.
- Do **not** use `-p` / headless mode anywhere. Normal subagent execution handles blocking commands fine.
- If `cmux` is not in PATH for a subagent, it must say so in its JSON error — do not silently succeed.
CMD_EOF

ok "/gsd-cmux-test (use inside a Claude Code session)"

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
echo "  ~/.claude/skills/gsd-cmux-bridge/SKILL.md        (~800 tok, global: bridge)"
echo "  ~/.claude/skills/gsd-cmux-orchestrator/SKILL.md  (~600 tok, global: orchestrator)"
$CMUX_SKILL_OK && echo "  ~/.claude/skills/using-cmux/                     (cmux skill)" || true
echo "  ~/.claude/scripts/gsd-spawn-agent.sh"
echo "  ~/.claude/scripts/gsd-wait-agent.sh"
echo "  ~/.claude/scripts/gsd-cmux-test.sh               (bash smoke test)"
echo "  ~/.claude/commands/gsd-cmux-test.md              (/gsd-cmux-test slash cmd)"
echo "  ~/.claude/settings.json                          (hooks)"
echo "  .planning/config.json                            (agent_skills per-agent-type)"
echo "  CLAUDE.md"
echo "  gsd-auto-cmux.sh"
echo ""
echo -e "${BOLD}Context economy:${NC}"
echo "  Bridge-only agents:    ~800 tokens  (verifier, planner, researcher, …)"
echo "  gsd-executor:         ~1400 tokens  (bridge + orchestrator)"
echo "  (vs ~5500 tokens in v1)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Open cmux terminal in project directory"
echo "  2. Verify the bridge, pick one:"
echo "       bash:   ~/.claude/scripts/gsd-cmux-test.sh"
echo "       claude: claude → /gsd-cmux-test"
echo "  3. If new project: claude → /gsd-new-project → /clear"
echo "  4. Run: ./gsd-auto-cmux.sh [phase]"
echo ""
