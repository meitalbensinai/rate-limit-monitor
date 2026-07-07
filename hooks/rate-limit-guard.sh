#!/usr/bin/env bash
# Rate Limit Monitor — UserPromptSubmit guard.
#
# When your 5-hour (or 7-day) usage window is at/above the threshold, this
# blocks the *new* prompt you just submitted — so you don't spend the rest of
# your window on a long token-heavy task and get cut off mid-run. Your session
# is untouched: you can wait for the reset and resubmit (this hook stops
# blocking automatically once the reset time passes), or approve right now.
#
# Approving WITHOUT polluting the prompt: just submit the SAME prompt again.
# The guard remembers the prompt it blocked and treats an identical resubmit as
# "yes, continue" — then stays quiet until that window resets, so you only
# confirm once per window. (The legacy override phrase still works too.)
#
# UserPromptSubmit hooks do NOT receive `rate_limits`, so we read the state
# file the statusline segment writes each turn. Approval is persisted in a
# SEPARATE ack file, because the statusline rewrites the state file every turn
# and would otherwise clobber it.
#
# Env:
#   RLM_THRESHOLD   block at/above this percent (default 90)
#   RLM_OVERRIDE    legacy phrase that, if present in the prompt, forces through
#                   AND approves the window (default "!limit-ok")
#   RLM_STATE_FILE  usage state file (default ~/.claude/.rate-limit-state.json)
#   RLM_ACK_FILE    approval state file (default ~/.claude/.rate-limit-ack.json)
#   RLM_WINDOWS     which windows to guard: "5h", "7d", or "both" (default both)
#
# Requires: jq. Block mechanism for UserPromptSubmit is exit code 2 with the
# message on stderr.
set -euo pipefail

THRESHOLD="${RLM_THRESHOLD:-90}"
OVERRIDE="${RLM_OVERRIDE:-!limit-ok}"
STATE_FILE="${RLM_STATE_FILE:-$HOME/.claude/.rate-limit-state.json}"
ACK_FILE="${RLM_ACK_FILE:-$HOME/.claude/.rate-limit-ack.json}"
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

# Normalize the reset epoch we'll persist (missing → 0, so the JSON stays valid).
wr="$worst_reset"; case "$wr" in ''|null) wr=0 ;; esac

# Already approved THIS window (resubmit-confirmed or phrase earlier) → allow.
ack_until=0
if [ -f "$ACK_FILE" ]; then
  ack_until="$(jq -r '.ack_until // 0' "$ACK_FILE" 2>/dev/null || echo 0)"
fi
if [ -n "$ack_until" ] && [ "$ack_until" != "null" ] && [ "$now" -lt "$ack_until" ] 2>/dev/null; then
  exit 0
fi

# Legacy phrase override → approve the window right now (persists until reset).
case "$prompt" in
  *"$OVERRIDE"*)
    printf '{"ack_until":%s}\n' "$wr" > "$ACK_FILE" 2>/dev/null || true
    exit 0 ;;
esac

# Resubmit-to-confirm: if this exact prompt is the one we just blocked (same
# window), treat the resubmit as approval and unblock the rest of the window.
cur_hash="$(printf '%s' "$prompt" | cksum | awk '{print $1"-"$2}')"
pending_hash=""; pending_reset=0
if [ -f "$ACK_FILE" ]; then
  pending_hash="$(jq -r '.pending_hash // empty' "$ACK_FILE" 2>/dev/null || true)"
  pending_reset="$(jq -r '.pending_reset // 0' "$ACK_FILE" 2>/dev/null || echo 0)"
fi
if [ -n "$pending_hash" ] && [ "$pending_hash" = "$cur_hash" ] \
   && [ -n "$pending_reset" ] && [ "$pending_reset" != "null" ] \
   && [ "$now" -lt "$pending_reset" ] 2>/dev/null; then
  printf '{"ack_until":%s}\n' "$wr" > "$ACK_FILE" 2>/dev/null || true
  exit 0
fi

# First time over the bar for this prompt → record it so an identical resubmit
# confirms, then block.
printf '{"pending_hash":"%s","pending_reset":%s}\n' "$cur_hash" "$wr" > "$ACK_FILE" 2>/dev/null || true

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

  • CONTINUE: send this SAME prompt again (press ↑ then Enter) to confirm — I
              won't ask again until the ${worst_label} window resets (~${reset_h}).
  • WAIT:     do nothing; the guard clears itself once the window resets, then
              resubmit whenever you like.

Heavy tasks worth pausing here: evals, Workflow runs, deep-research, large refactors.
EOF
exit 2
