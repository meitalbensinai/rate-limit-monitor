#!/usr/bin/env bash
# Rate Limit Monitor — PreToolUse loop guard.
#
# Fires before every tool call inside the model's agentic loop. If your 5-hour
# (or 7-day) usage is at/above the threshold AND you haven't approved this
# window, it DENIES the tool call — halting a long, multi-step model run before
# it drains the rest of your window. The model gets the reason and surfaces it;
# you approve by resubmitting your prompt (the UserPromptSubmit guard writes a
# per-window ack that this guard honors), after which the loop runs freely
# until the window resets.
#
# Caveat — freshness: PreToolUse hooks do NOT receive `rate_limits`. This reads
# the state file the statusline writes, so it is only as fresh as the last
# statusline render. It catches a loop that crosses the threshold about as fast
# as the statusline refreshes, not instantly per tool call.
#
# Env:
#   RLM_GUARD_LOOP  set to 0 to disable this guard entirely (default 1)
#   RLM_THRESHOLD   deny at/above this percent (default 90)
#   RLM_STATE_FILE  usage state file (default ~/.claude/.rate-limit-state.json)
#   RLM_ACK_FILE    approval state file (default ~/.claude/.rate-limit-ack.json)
#   RLM_WINDOWS     which windows to guard: "5h", "7d", or "both" (default both)
#
# Requires: jq. Deny mechanism for PreToolUse is a JSON permissionDecision
# "deny" on stdout (exit 0). Anything else → allow.
set -euo pipefail

# Drain the tool payload on stdin; we don't need it.
cat >/dev/null 2>&1 || true

[ "${RLM_GUARD_LOOP:-1}" = "0" ] && exit 0

THRESHOLD="${RLM_THRESHOLD:-90}"
STATE_FILE="${RLM_STATE_FILE:-$HOME/.claude/.rate-limit-state.json}"
ACK_FILE="${RLM_ACK_FILE:-$HOME/.claude/.rate-limit-ack.json}"
WINDOWS="${RLM_WINDOWS:-both}"

# No usage reading yet → allow (fail open).
[ -f "$STATE_FILE" ] || exit 0

five="$(jq -r '.five // empty'        "$STATE_FILE" 2>/dev/null || true)"
five_reset="$(jq -r '.five_reset // empty'  "$STATE_FILE" 2>/dev/null || true)"
seven="$(jq -r '.seven // empty'      "$STATE_FILE" 2>/dev/null || true)"
seven_reset="$(jq -r '.seven_reset // empty' "$STATE_FILE" 2>/dev/null || true)"

now="$(date +%s)"
worst_int=-1; worst_label=""

consider() { # $1=label $2=pct $3=reset_epoch
  local l="$1" p="$2" r="$3" i
  [ -z "$p" ] || [ "$p" = "null" ] && return
  if [ -n "$r" ] && [ "$r" != "null" ] && [ "$now" -ge "$r" ] 2>/dev/null; then return; fi
  i="${p%.*}"
  if [ "$i" -gt "$worst_int" ] 2>/dev/null; then
    worst_int="$i"; worst_label="$l"
  fi
}

case "$WINDOWS" in
  5h)   consider "5-hour" "$five" "$five_reset" ;;
  7d)   consider "7-day" "$seven" "$seven_reset" ;;
  *)    consider "5-hour" "$five" "$five_reset"; consider "7-day" "$seven" "$seven_reset" ;;
esac

# Under the bar → allow.
[ "$worst_int" -lt "$THRESHOLD" ] 2>/dev/null && exit 0
[ "$worst_int" -lt 0 ] && exit 0

# Already approved this window (via the prompt guard) → let the loop run.
ack_until=0
if [ -f "$ACK_FILE" ]; then
  ack_until="$(jq -r '.ack_until // 0' "$ACK_FILE" 2>/dev/null || echo 0)"
fi
if [ -n "$ack_until" ] && [ "$ack_until" != "null" ] && [ "$now" -lt "$ack_until" ] 2>/dev/null; then
  exit 0
fi

# Over threshold, not approved → deny this tool call to pause the loop.
reason="Rate Limit Monitor: your ${worst_label} limit is at ${worst_int}% (threshold ${THRESHOLD}%). Pausing the agentic loop to preserve the rest of your usage window. Stop here and tell the user; to continue, they should resubmit their prompt to confirm — that unblocks the loop until the window resets."
jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
