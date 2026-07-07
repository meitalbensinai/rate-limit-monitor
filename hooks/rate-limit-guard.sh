#!/usr/bin/env bash
# Rate Limit Monitor — UserPromptSubmit guard.
#
# When your 5-hour (or 7-day) usage window is at/above the threshold, this
# blocks the *new* prompt you just submitted — so you don't spend the rest of
# your window on a long token-heavy task and get cut off mid-run. Your session
# is untouched: you can wait for the reset and resubmit (this hook stops
# blocking automatically once the reset time passes), or override right now.
#
# UserPromptSubmit hooks do NOT receive `rate_limits`, so we read the state
# file the statusline segment writes each turn.
#
# Env:
#   RLM_THRESHOLD   block at/above this percent (default 90)
#   RLM_OVERRIDE    phrase that, if present in the prompt, forces through
#                   (default "!limit-ok")
#   RLM_STATE_FILE  state file path (default ~/.claude/.rate-limit-state.json)
#   RLM_WINDOWS     which windows to guard: "5h", "7d", or "both" (default both)
#
# Requires: jq. Block mechanism for UserPromptSubmit is exit code 2 with the
# message on stderr.
set -euo pipefail

THRESHOLD="${RLM_THRESHOLD:-90}"
OVERRIDE="${RLM_OVERRIDE:-!limit-ok}"
STATE_FILE="${RLM_STATE_FILE:-$HOME/.claude/.rate-limit-state.json}"
WINDOWS="${RLM_WINDOWS:-both}"

input="$(cat)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null || echo '')"

# No state yet (no rate-limit reading seen this session) → allow.
[ -f "$STATE_FILE" ] || exit 0

five="$(jq -r '.five // empty'        "$STATE_FILE" 2>/dev/null || true)"
five_reset="$(jq -r '.five_reset // empty'  "$STATE_FILE" 2>/dev/null || true)"
seven="$(jq -r '.seven // empty'      "$STATE_FILE" 2>/dev/null || true)"
seven_reset="$(jq -r '.seven_reset // empty' "$STATE_FILE" 2>/dev/null || true)"

now="$(date +%s)"
worst_int=-1; worst_label=""; worst_reset=""

consider() { # $1=label $2=pct $3=reset_epoch
  local l="$1" p="$2" r="$3" i
  [ -z "$p" ] || [ "$p" = "null" ] && return
  # Window already reset → the stored reading is stale, ignore it.
  if [ -n "$r" ] && [ "$r" != "null" ] && [ "$now" -ge "$r" ] 2>/dev/null; then return; fi
  i="${p%.*}"
  if [ "$i" -gt "$worst_int" ] 2>/dev/null; then
    worst_int="$i"; worst_label="$l"; worst_reset="$r"
  fi
}

case "$WINDOWS" in
  5h)   consider "5-hour" "$five" "$five_reset" ;;
  7d)   consider "7-day" "$seven" "$seven_reset" ;;
  *)    consider "5-hour" "$five" "$five_reset"; consider "7-day" "$seven" "$seven_reset" ;;
esac

# Nothing over the bar → allow.
[ "$worst_int" -lt "$THRESHOLD" ] 2>/dev/null && exit 0
[ "$worst_int" -lt 0 ] && exit 0

# Over threshold. Allow if the override phrase appears anywhere in the prompt.
case "$prompt" in
  *"$OVERRIDE"*) exit 0 ;;
esac

if [ -n "$worst_reset" ] && [ "$worst_reset" != "null" ]; then
  diff=$(( worst_reset - now )); [ "$diff" -lt 0 ] && diff=0
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then reset_h="${d}d${h}h"
  elif [ "$h" -gt 0 ]; then reset_h="${h}h${m}m"
  else                       reset_h="${m}m"
  fi
else
  reset_h='a while'
fi

cat >&2 <<EOF
■ Usage guard — your ${worst_label} limit is at ${worst_int}% (threshold ${THRESHOLD}%).

This prompt was NOT sent, to preserve the rest of your window. Your session is
intact, so you lose no context.

  • WAIT:        pause until the ${worst_label} window resets (~${reset_h}), then
                 resubmit this same prompt — the guard clears itself after reset.
  • CONTINUE NOW: resend with "${OVERRIDE}" anywhere in your message to override.

Heavy tasks worth pausing here: evals, Workflow runs, deep-research, large refactors.
EOF
exit 2
