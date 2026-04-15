#!/usr/bin/env bash
# uninstall-gsd-cmux.sh — remove all artifacts created by setup-gsd-cmux.sh
# (all versions up through v5.4.0).
#
# Scope:
#   ~/.claude/skills/gsd-cmux-bridge/
#   ~/.claude/skills/gsd-cmux-orchestrator/
#   ~/.claude/scripts/gsd-{spawn,wait}-agent.sh
#   ~/.claude/scripts/gsd-cmux-test.sh
#   ~/.claude/commands/gsd-cmux-test.md
#   ~/.claude/settings.json           — strips our two hook entries, keeps everything else
#   $PROJECT/.planning/config.json    — strips our two global: skill refs from agent_skills
#   $PROJECT/CLAUDE.md                — strips the <!-- gsd-cmux-bridge --> marker block
#   $PROJECT/gsd-auto-cmux.sh
#   *.bak backups created by prior runs (optional, asked)
#
# Flags:
#   --yes        skip all prompts (accept every removal)
#   --keep-bak   do not clean up *.bak backup files
#   --dry-run    print actions without doing them
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
skip() { printf '%s·%s %s\n' "$YELLOW" "$NC" "$*"; }

# ── Flags ────────────────────────────────────────────────────────────────────
AUTO_YES=0; KEEP_BAK=0; DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y)   AUTO_YES=1 ;;
    --keep-bak) KEEP_BAK=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "Unknown flag: $arg (use --help)" ;;
  esac
done

ask() {
  local prompt="$1"
  if [ "$AUTO_YES" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then return 0; fi   # non-interactive → proceed
  printf '%s? %s%s [Y/n] ' "$YELLOW" "$prompt" "$NC" >&2
  read -r ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %s(dry-run)%s %s\n' "$YELLOW" "$NC" "$*"
    return 0
  fi
  "$@"
}

# ── Paths ────────────────────────────────────────────────────────────────────
CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$CLAUDE_DIR/skills"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"
PROJECT_DIR="$PWD"
PLANNING_CONFIG="$PROJECT_DIR/.planning/config.json"
CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"
LAUNCHER="$PROJECT_DIR/gsd-auto-cmux.sh"

# Banner
printf '%s%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$BLUE" "$NC"
printf '%s%s  gsd-cmux uninstall%s\n' "$BOLD" "$BLUE" "$NC"
printf '%s%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$BLUE" "$NC"
echo "  Project:     $PROJECT_DIR"
echo "  Global dir:  $CLAUDE_DIR"
[ "$DRY_RUN" = "1" ] && warn "DRY-RUN mode — no changes will be written"
echo ""

# ── 1. Skills ────────────────────────────────────────────────────────────────
log "Skills (~/.claude/skills/)"
for d in gsd-cmux-bridge gsd-cmux-orchestrator; do
  p="$SKILLS_DIR/$d"
  if [ -e "$p" ]; then
    if ask "Remove $p"; then
      run rm -rf "$p"
      ok "removed $d"
    else
      skip "kept $d"
    fi
  else
    skip "$d (not present)"
  fi
done

# ── 2. Helper scripts ────────────────────────────────────────────────────────
log "Helper scripts (~/.claude/scripts/)"
for f in gsd-spawn-agent.sh gsd-wait-agent.sh gsd-cmux-test.sh; do
  p="$SCRIPTS_DIR/$f"
  if [ -e "$p" ]; then
    if ask "Remove $p"; then
      run rm -f "$p"
      ok "removed $f"
    else
      skip "kept $f"
    fi
  else
    skip "$f (not present)"
  fi
done

# ── 3. Slash commands ────────────────────────────────────────────────────────
log "Slash commands (~/.claude/commands/)"
for f in gsd-cmux-test.md; do
  p="$COMMANDS_DIR/$f"
  if [ -e "$p" ]; then
    if ask "Remove $p"; then
      run rm -f "$p"
      ok "removed $f"
    else
      skip "kept $f"
    fi
  else
    skip "$f (not present)"
  fi
done

# ── 4. settings.json — strip only our two hook commands ──────────────────────
log "Claude settings.json hooks"
if [ -f "$SETTINGS" ]; then
  if ask "Strip gsd-cmux hooks from $SETTINGS"; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '  %s(dry-run)%s would strip hooks from %s\n' "$YELLOW" "$NC" "$SETTINGS"
    else
      python3 - "$SETTINGS" << 'PYEOF' || err "Failed to edit settings.json"
import json, os, sys, time, shutil

path = sys.argv[1]
with open(path) as f:
    original = f.read()
cfg = json.loads(original) if original.strip() else {}

# Our two hook commands, identified by fragment substrings.
# Match loosely so minor quoting variations still get removed.
BRIDGE_FRAGMENTS = (
    'cmux log --level success --source gsd -- "Subagent done"',
    'cmux notify --title "GSD" --body "Session ended"',
)

def is_ours(cmd: str) -> bool:
    return isinstance(cmd, str) and any(f in cmd for f in BRIDGE_FRAGMENTS)

hooks = cfg.get("hooks") or {}
removed_cnt = 0
for event in list(hooks.keys()):
    new_entries = []
    for entry in hooks.get(event, []):
        inner = entry.get("hooks", [])
        kept_inner = [h for h in inner if not is_ours(h.get("command", ""))]
        dropped = len(inner) - len(kept_inner)
        removed_cnt += dropped
        if kept_inner:
            entry["hooks"] = kept_inner
            new_entries.append(entry)
        # else: entry becomes empty → drop it
    if new_entries:
        hooks[event] = new_entries
    else:
        hooks.pop(event, None)

if hooks:
    cfg["hooks"] = hooks
else:
    cfg.pop("hooks", None)

new_text = json.dumps(cfg, indent=2) + "\n"
if new_text == original:
    print("no-op (no matching hooks)")
    sys.exit(0)

shutil.copy2(path, f"{path}.{int(time.time())}.bak")
with open(path, "w") as f:
    f.write(new_text)
print(f"stripped {removed_cnt} hook command(s)")
PYEOF
      ok "settings.json"
    fi
  else
    skip "kept settings.json"
  fi
else
  skip "settings.json (not present)"
fi

# ── 5. .planning/config.json — strip our global: skill refs ──────────────────
log "GSD config.json agent_skills"
if [ -f "$PLANNING_CONFIG" ]; then
  if ask "Strip gsd-cmux skill refs from $PLANNING_CONFIG"; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '  %s(dry-run)%s would strip agent_skills entries from %s\n' "$YELLOW" "$NC" "$PLANNING_CONFIG"
    else
      python3 - "$PLANNING_CONFIG" << 'PYEOF' || err "Failed to edit config.json"
import json, sys, time, shutil

path = sys.argv[1]
with open(path) as f:
    original = f.read()
cfg = json.loads(original) if original.strip() else {}

OURS = {"global:gsd-cmux-bridge", "global:gsd-cmux-orchestrator"}

agent_skills = cfg.get("agent_skills")
removed_cnt = 0
if isinstance(agent_skills, dict):
    for agent in list(agent_skills.keys()):
        lst = agent_skills.get(agent)
        if isinstance(lst, list):
            kept = [x for x in lst if x not in OURS]
            removed_cnt += len(lst) - len(kept)
            if kept:
                agent_skills[agent] = kept
            else:
                # empty list → drop the key entirely so GSD doesn't render "[]"
                agent_skills.pop(agent, None)
        elif lst in OURS:
            removed_cnt += 1
            agent_skills.pop(agent, None)
elif isinstance(agent_skills, list):
    # Legacy (≤5.3.x): flat list. Strip matching refs.
    kept = [x for x in agent_skills if x not in OURS]
    removed_cnt = len(agent_skills) - len(kept)
    cfg["agent_skills"] = kept

# Drop legacy phase_skills if we created it in earlier versions
if "phase_skills" in cfg and isinstance(cfg["phase_skills"], dict):
    # Only drop if its values reference our skills
    pv = cfg["phase_skills"]
    flat = [r for refs in pv.values() if isinstance(refs, list) for r in refs]
    if flat and all(r in OURS or "gsd-cmux" in str(r) for r in flat):
        cfg.pop("phase_skills", None)

new_text = json.dumps(cfg, indent=2) + "\n"
if new_text == original:
    print("no-op (no matching skill refs)")
    sys.exit(0)

shutil.copy2(path, f"{path}.{int(time.time())}.bak")
with open(path, "w") as f:
    f.write(new_text)
print(f"stripped {removed_cnt} skill ref(s)")
PYEOF
      ok "config.json"
    fi
  else
    skip "kept config.json"
  fi
else
  skip ".planning/config.json (not present — not a GSD project?)"
fi

# ── 6. CLAUDE.md — strip marker block ────────────────────────────────────────
log "CLAUDE.md marker block"
if [ -f "$CLAUDE_MD" ] && grep -q '<!-- gsd-cmux-bridge -->' "$CLAUDE_MD"; then
  if ask "Strip the gsd-cmux-bridge block from $CLAUDE_MD"; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '  %s(dry-run)%s would strip block from %s\n' "$YELLOW" "$NC" "$CLAUDE_MD"
    else
      python3 - "$CLAUDE_MD" << 'PYEOF' || err "Failed to edit CLAUDE.md"
import sys, re, time, shutil
path = sys.argv[1]
with open(path) as f:
    text = f.read()
# Pattern: marker line + "## cmux" heading + indented body, up to next blank
# separator or another ##-heading or EOF. Install script appended:
#   <!-- gsd-cmux-bridge -->\n## cmux\nIf `$CMUX_SOCKET_PATH` set → follow `~/.claude/skills/gsd-cmux-bridge/SKILL.md`
pattern = re.compile(
    r'(?:\n{1,2})?<!-- gsd-cmux-bridge -->\n## cmux\n[^\n]*(?:\n(?!## )[^\n]*)*',
    re.MULTILINE,
)
new_text = pattern.sub('', text)
# Collapse accidental triple-newlines created by removal
new_text = re.sub(r'\n{3,}', '\n\n', new_text)
if new_text == text:
    print("no-op")
    sys.exit(0)
shutil.copy2(path, f"{path}.{int(time.time())}.bak")
with open(path, "w") as f:
    f.write(new_text)
print("stripped")
PYEOF
      ok "CLAUDE.md"
    fi
  else
    skip "kept CLAUDE.md"
  fi
else
  skip "CLAUDE.md (no marker found)"
fi

# ── 7. Launcher ──────────────────────────────────────────────────────────────
log "Project launcher"
if [ -f "$LAUNCHER" ]; then
  if ask "Remove $LAUNCHER"; then
    run rm -f "$LAUNCHER"
    ok "removed gsd-auto-cmux.sh"
  else
    skip "kept gsd-auto-cmux.sh"
  fi
else
  skip "gsd-auto-cmux.sh (not present)"
fi

# ── 8. Backups ───────────────────────────────────────────────────────────────
if [ "$KEEP_BAK" = "1" ]; then
  log "Backups — kept (--keep-bak)"
else
  log "Backups (*.bak)"
  # Only backups generated by install / this script live next to these files
  CANDIDATES=(
    "$SETTINGS"
    "$PLANNING_CONFIG"
    "$CLAUDE_MD"
  )
  for base in "${CANDIDATES[@]}"; do
    # Expand *.bak safely via shell glob; skip if no match
    # shellcheck disable=SC2231
    for b in "${base}".*.bak; do
      [ -e "$b" ] || continue
      if ask "Remove backup $b"; then
        run rm -f "$b"
        ok "removed $(basename "$b")"
      else
        skip "kept $(basename "$b")"
      fi
    done
  done
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
printf '%s%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$GREEN" "$NC"
printf '%s%s  Uninstall complete%s\n' "$BOLD" "$GREEN" "$NC"
printf '%s%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$GREEN" "$NC"
echo ""
echo "What was NOT touched:"
echo "  • ~/.claude/skills/using-cmux/       (third-party, installed separately)"
echo "  • GSD hooks from get-shit-done-cc     (gsd-*.js in ~/.claude/hooks/)"
echo "  • Any agent_skills entries that are not 'global:gsd-cmux-*'"
echo "  • Any settings.json hooks that are not our cmux log/notify commands"
echo ""
[ "$DRY_RUN" = "1" ] && warn "DRY-RUN: nothing was actually changed. Re-run without --dry-run to apply."
