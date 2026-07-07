#!/usr/bin/env bash
# Rate Limit Monitor — uninstaller. Reverses install.sh: removes the
# UserPromptSubmit guard and the PreToolUse loop guard, and either restores your
# original statusline (if we wrapped one) or drops the statusLine entry (if we
# added it). Other hooks are left untouched. Idempotent; backs up first.
#
# Usage:  bash ./uninstall.sh
set -euo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
info() { printf '  %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required." >&2; exit 1; }
[ -f "$SETTINGS" ] || { echo "No settings.json at $SETTINGS — nothing to do."; exit 0; }
jq empty "$SETTINGS" >/dev/null 2>&1 || { echo "ERROR: $SETTINGS is not valid JSON." >&2; exit 1; }

BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "Uninstalling Rate Limit Monitor ← $SETTINGS"
info "backup: $BACKUP"

# 1. Drop any UserPromptSubmit group whose command references our guard.
tmp="$(mktemp)"
jq '
  if .hooks.UserPromptSubmit then
    .hooks.UserPromptSubmit |= map(select(
      any(.hooks[]?; (.command // "") | contains("rate-limit-guard.sh")) | not
    ))
    | (if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end)
  else . end
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# 2. Drop any PreToolUse group whose command references our loop guard.
tmp="$(mktemp)"
jq '
  if .hooks.PreToolUse then
    .hooks.PreToolUse |= map(select(
      any(.hooks[]?; (.command // "") | contains("rate-limit-loop-guard.sh")) | not
    ))
    | (if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end)
  else . end
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# 3. Restore / remove statusline.
sl="$(jq -r '.statusLine.command // ""' "$SETTINGS")"
if printf '%s' "$sl" | grep -q "rate-limit-statusline.sh"; then
  # Was it a wrap of a prior statusline? Recover the inner command if so.
  inner="$(printf '%s' "$sl" | sed -n "s/^RLM_INNER_STATUSLINE='\(.*\)' bash .*rate-limit-statusline\.sh.*$/\1/p")"
  tmp="$(mktemp)"
  if [ -n "$inner" ]; then
    jq --arg cmd "$inner" '.statusLine = {type:"command", command:$cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    info "statusline: restored your original ✓"
  else
    jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    info "statusline: removed ✓"
  fi
else
  info "statusline: not ours — left untouched"
fi

jq empty "$SETTINGS" >/dev/null 2>&1 || { echo "ERROR: settings invalid; restoring." >&2; cp "$BACKUP" "$SETTINGS"; exit 1; }
echo
echo "Done. RESTART Claude Code. (State file ~/.claude/.rate-limit-state.json can be deleted.)"
