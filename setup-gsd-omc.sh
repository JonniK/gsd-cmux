#!/usr/bin/env bash
# setup-gsd-omc.sh — install the thin GSD↔OMC adapter
#
# Scope:
#   ~/.claude/skills/gsd-omc-bridge/SKILL.md  — worker contract
#   ~/.claude/commands/gsd-omc-execute.md     — single-phase orchestrator
#   ~/.claude/commands/gsd-omc-run.md         — full-lifecycle entry point
#   ~/.claude/commands/gsd-omc-verify.md      — end-to-end smoke test
#   $PROJECT/.planning/config.json            — agent_skills += global:gsd-omc-bridge
#
# Intentionally does NOT touch:
#   ~/.claude/settings.json  — OMC and GSD own their own hooks; we add none.
#   ~/.claude/hooks/         — same.
#
# Flags:
#   --yes       skip all prompts (accept every overwrite)
#   --dry-run   print actions without doing them
#   --no-global only write project-scoped files (skip ~/.claude)
#
# See DESIGN.md.
set -euo pipefail

# ── Colors / logging ─────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; NC=$'\e[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi
log()  { printf '%s▶%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

# ── Flags ────────────────────────────────────────────────────────────────────
AUTO_YES=0; DRY_RUN=0; NO_GLOBAL=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y)    AUTO_YES=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --no-global) NO_GLOBAL=1 ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Unknown flag: $arg (use --help)" ;;
  esac
done

ask() {
  local prompt="$1"
  if [ "$AUTO_YES" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then return 0; fi
  printf '%s? %s%s [Y/n] ' "$YELLOW" "$prompt" "$NC" >&2
  read -r ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# ── write_file — idempotent with 3 branches (new / unchanged / differs+backup) ─
# Memory: feedback_idempotency_infra_before_rerun.md
# Usage:  write_file <abs-path> <desc> < source
write_file() {
  local path="$1" desc="$2" tmp
  tmp=$(mktemp)
  cat > "$tmp"

  if [ "$DRY_RUN" = "1" ]; then
    if [ ! -f "$path" ]; then
      printf '  %s(dry-run)%s would create %s (%s)\n' "$YELLOW" "$NC" "$path" "$desc"
    elif cmp -s "$tmp" "$path"; then
      printf '  %s(dry-run)%s %s unchanged\n' "$YELLOW" "$NC" "$path"
    else
      printf '  %s(dry-run)%s would overwrite %s (backup kept)\n' "$YELLOW" "$NC" "$path"
    fi
    rm -f "$tmp"
    return 0
  fi

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

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$CLAUDE_DIR/skills"
COMMANDS_DIR="$CLAUDE_DIR/commands"
PROJECT_DIR="$PWD"
PLANNING_DIR="$PROJECT_DIR/.planning"

# Banner
printf '%s%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$BLUE" "$NC"
printf '%s%s  gsd-omc adapter install%s\n' "$BOLD" "$BLUE" "$NC"
printf '%s%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$BLUE" "$NC"
echo "  Repo:        $REPO_DIR"
echo "  Project:     $PROJECT_DIR"
echo "  Global dir:  $CLAUDE_DIR"
[ "$DRY_RUN" = "1" ]  && warn "DRY-RUN mode — no changes will be written"
[ "$NO_GLOBAL" = "1" ] && warn "NO-GLOBAL mode — ~/.claude will not be touched"
echo ""

# ── Preflight ────────────────────────────────────────────────────────────────
log "Preflight"

# Registry probe, not execute (memory: feedback_registry_probe_not_execute.md).
# Use --version for the CLIs we need on PATH; they're cheap and non-interactive.
for cmd in omc cmux claude node python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$cmd not on PATH — install it first (omc: \`npm i -g oh-my-claude-sisyphus\`)"
  fi
done
ok "binaries present: omc, cmux, claude, node, python3"

OMC_VERSION="$(omc --version 2>/dev/null | head -1 || true)"
CMUX_VERSION="$(cmux --version 2>/dev/null | head -1 || true)"
ok "omc=$OMC_VERSION  cmux=$CMUX_VERSION"

# OMC doctor — warn but don't hard-fail (may have unrelated conflicts).
if ! omc doctor conflicts >/dev/null 2>&1; then
  warn "\`omc doctor conflicts\` exited non-zero — review manually if anything breaks"
fi

# ── 1. Skill: gsd-omc-bridge ────────────────────────────────────────────────
if [ "$NO_GLOBAL" = "0" ]; then
  log "Skill: gsd-omc-bridge"
  SRC_SKILL="$REPO_DIR/skills/gsd-omc-bridge/SKILL.md"
  [ -f "$SRC_SKILL" ] || err "Source skill missing: $SRC_SKILL"
  write_file "$SKILLS_DIR/gsd-omc-bridge/SKILL.md" "skills/gsd-omc-bridge/SKILL.md" < "$SRC_SKILL"
fi

# ── 2. Slash commands ────────────────────────────────────────────────────────
if [ "$NO_GLOBAL" = "0" ]; then
  log "Slash commands"
  for cmd_name in gsd-omc-execute gsd-omc-run gsd-omc-verify; do
    SRC_CMD="$REPO_DIR/commands/$cmd_name.md"
    if [ -f "$SRC_CMD" ]; then
      write_file "$COMMANDS_DIR/$cmd_name.md" "commands/$cmd_name.md" < "$SRC_CMD"
    else
      warn "$SRC_CMD missing — skip (authored later in PLAN Phases D/E/F)"
    fi
  done
fi

# ── 3. GSD config.json — agent_skills ────────────────────────────────────────
# Memory: feedback_read_consumer_before_writing_config.md.
# GSD's init.cjs: `agent_skills` is an OBJECT keyed by agent-type; values are
# arrays of `global:<name>` refs. validatePath rejects abs paths silently.
log "GSD config.json agent_skills"

if [ -d "$PLANNING_DIR" ]; then
  GSD_CONFIG="$PLANNING_DIR/config.json"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %s(dry-run)%s would merge global:gsd-omc-bridge into %s\n' "$YELLOW" "$NC" "$GSD_CONFIG"
  else
    python3 - "$GSD_CONFIG" << 'PYEOF' || err "Failed to configure GSD config.json"
import json, os, sys, time, shutil

config_path = sys.argv[1]
existed = os.path.exists(config_path)

# Scope: only gsd-executor loads the adapter skill. Other agents don't run
# worker lifecycle; loading the skill would be noise in their context.
NEW_REF = "global:gsd-omc-bridge"
TARGET_AGENTS = ["gsd-executor"]

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

# Coerce unexpected agent_skills shapes (non-dict) into the correct form.
# GSD's init.cjs validates agent_skills as an object keyed by agent-type.
if not isinstance(cfg.get("agent_skills"), dict):
    cfg["agent_skills"] = {}

# Add our ref to target agents (idempotent).
def ensure(agent, ref):
    lst = cfg["agent_skills"].get(agent)
    if not isinstance(lst, list):
        lst = [] if lst is None else [lst]
    if ref not in lst:
        lst.append(ref)
    cfg["agent_skills"][agent] = lst

for a in TARGET_AGENTS:
    ensure(a, NEW_REF)

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
  fi
  ok "config.json (agent_skills += global:gsd-omc-bridge on gsd-executor)"
else
  warn ".planning/ not present — skipping config.json (not a GSD project, or run from project root)"
fi

# ── 4. Explicit non-actions ──────────────────────────────────────────────────
log "NOT touched (by design)"
echo "  • ~/.claude/settings.json  — OMC + GSD own hooks; we add none"
echo "  • ~/.claude/hooks/         — same"
echo "  • ~/.claude/skills/using-cmux/ — third-party, installed separately"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
printf '%s%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$GREEN" "$NC"
printf '%s%s  Install complete%s\n' "$BOLD" "$GREEN" "$NC"
printf '%s%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$GREEN" "$NC"
echo ""
echo "Try it:"
echo "  /gsd-omc-verify           — end-to-end smoke test"
echo "  /gsd-omc-execute <phase>  — run one phase with panes"
echo "  /gsd-omc-run autonomous   — full-lifecycle from here"
echo ""
[ "$DRY_RUN" = "1" ] && warn "DRY-RUN: nothing was actually changed. Re-run without --dry-run to apply."
