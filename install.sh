#!/usr/bin/env bash
# Rate Limit Monitor — one-command installer.
#
# Safe and idempotent: backs up settings.json, then wires the statusline, the
# UserPromptSubmit guard, and the PreToolUse loop guard WITHOUT removing any
# existing statusline or hooks. Re-running it changes nothing. Works from
# wherever this repo lives (the wired paths point back at this checkout).
#
# Usage:  bash ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/hooks/rate-limit-guard.sh"
LOOP_GUARD="$SCRIPT_DIR/hooks/rate-limit-loop-guard.sh"
SL_SCRIPT="$SCRIPT_DIR/statusline/rate-limit-statusline.sh"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"

info() { printf '  %s\n' "$*"; }

# --- preflight ---------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' is required but not found. Install it (brew install jq / apt install jq) and re-run." >&2
  exit 1
fi
chmod +x "$GUARD" "$LOOP_GUARD" "$SL_SCRIPT" 2>/dev/null || true
mkdir -p "$CONFIG_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  echo "ERROR: $SETTINGS is not valid JSON. Fix or move it, then re-run." >&2
  exit 1
fi

# --- backup ------------------------------------------------------------------
BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

echo "Installing Rate Limit Monitor → $SETTINGS"
info "backup: $BACKUP"
changed=0

# --- 1. guard hook (append, don't clobber; skip if already present) ----------
if jq -e 'any(.hooks.UserPromptSubmit[]?; any(.hooks[]?; (.command // "") | contains("rate-limit-guard.sh")))' \
     "$SETTINGS" >/dev/null 2>&1; then
  info "hook:       already wired ✓"
else
  tmp="$(mktemp)"
  jq --arg guard "$GUARD" '
    .hooks = (.hooks // {})
    | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [])
        + [ { "hooks": [ { "type": "command", "command": $guard } ] } ])
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  info "hook:       added UserPromptSubmit guard ✓"
  changed=1
fi

# --- 2. loop guard (PreToolUse; append, don't clobber; skip if present) ------
if jq -e 'any(.hooks.PreToolUse[]?; any(.hooks[]?; (.command // "") | contains("rate-limit-loop-guard.sh")))' \
     "$SETTINGS" >/dev/null 2>&1; then
  info "loop guard: already wired ✓"
else
  tmp="$(mktemp)"
  jq --arg cmd "$LOOP_GUARD" '
    .hooks = (.hooks // {})
    | .hooks.PreToolUse = ((.hooks.PreToolUse // [])
        + [ { "matcher": "*", "hooks": [ { "type": "command", "command": $cmd } ] } ])
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  info "loop guard: added PreToolUse guard ✓"
  changed=1
fi

# --- 3. statusline (chain any existing one; skip if already ours) ------------
existing_sl="$(jq -r '.statusLine.command // ""' "$SETTINGS")"
if printf '%s' "$existing_sl" | grep -q "rate-limit-statusline.sh"; then
  info "statusline: already wired ✓"
else
  if [ -n "$existing_sl" ]; then
    case "$existing_sl" in
      *\'*) info "NOTE: existing statusLine contains a single quote — verify the wrapped command below." ;;
    esac
    new_sl="RLM_INNER_STATUSLINE='$existing_sl' bash $SL_SCRIPT"
    info "statusline: wrapped your existing statusline ✓"
  else
    new_sl="bash $SL_SCRIPT"
    info "statusline: set (no previous statusline found) ✓"
  fi
  tmp="$(mktemp)"
  jq --arg cmd "$new_sl" '.statusLine = {type:"command", command:$cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  changed=1
fi

# --- verify & finish ---------------------------------------------------------
if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  echo "ERROR: settings became invalid; restoring backup." >&2
  cp "$BACKUP" "$SETTINGS"
  exit 1
fi

echo
if [ "$changed" -eq 1 ]; then
  echo "Done. RESTART Claude Code to load the statusline + guards."
else
  echo "Already installed — nothing to change."
fi
echo "Tune with env vars (see README): RLM_THRESHOLD, RLM_WINDOWS, RLM_OVERRIDE, RLM_GUARD_LOOP."
echo "Uninstall any time with: bash \"$SCRIPT_DIR/uninstall.sh\""
