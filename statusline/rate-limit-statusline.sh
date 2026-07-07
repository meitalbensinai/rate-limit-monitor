#!/usr/bin/env bash
# Rate Limit Monitor — statusline segment.
#
# Claude Code passes usage info as JSON on stdin. Only the statusline receives
# the official `rate_limits` block (UserPromptSubmit hooks do NOT), so this
# script is also the *source of truth* that persists the current percentages +
# reset times to a small state file the guard hook reads.
#
# It optionally chains an existing statusline command first, so it can wrap a
# user's current prompt instead of replacing it.
#
# Env:
#   RLM_INNER_STATUSLINE   shell command to run first; its stdout is prefixed
#                          to our segment (it receives the same stdin JSON).
#                          e.g. "bash ~/.claude/statusline-command.sh"
#   RLM_STATE_FILE         state file path (default ~/.claude/.rate-limit-state.json)
#
# Requires: jq. Note: `rate_limits` is present only for Pro/Max/Team/Enterprise
# plans, and only after the first API response of a session.
set -euo pipefail

STATE_FILE="${RLM_STATE_FILE:-$HOME/.claude/.rate-limit-state.json}"
INNER="${RLM_INNER_STATUSLINE:-}"

input="$(cat)"

# 1. Chain an existing statusline, if configured (feed it the same JSON).
base=""
if [ -n "$INNER" ]; then
  base="$(printf '%s' "$input" | bash -c "$INNER" 2>/dev/null)" || base=""
  base="${base%$'\n'}"
fi

# 2. Pull official rate-limit data.
five="$(printf '%s' "$input"       | jq -r '.rate_limits.five_hour.used_percentage // empty')"
five_reset="$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')"
seven="$(printf '%s' "$input"      | jq -r '.rate_limits.seven_day.used_percentage // empty')"
seven_reset="$(printf '%s' "$input"| jq -r '.rate_limits.seven_day.resets_at // empty')"

# No usage data (non-subscriber, or before first API response): just pass base through.
if [ -z "$five" ] && [ -z "$seven" ]; then
  [ -n "$base" ] && printf '%s\n' "$base"
  exit 0
fi

# 3. Persist for the guard hook (hooks can't see rate_limits themselves).
printf '{"five":%s,"five_reset":%s,"seven":%s,"seven_reset":%s}\n' \
  "${five:-null}" "${five_reset:-null}" "${seven:-null}" "${seven_reset:-null}" \
  > "$STATE_FILE" 2>/dev/null || true

# Format the time until an epoch as a compact delta: "2d3h", "2h14m", "45m", "now".
fmt_delta() { # $1=reset_epoch
  local reset="$1" now diff d h m
  if [ -z "$reset" ] || [ "$reset" = "null" ]; then printf '?'; return; fi
  now="$(date +%s)"
  diff=$(( reset - now ))
  if [ "$diff" -le 0 ]; then printf 'now'; return; fi
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else                       printf '%dm' "$m"
  fi
}

# 4. Render a colored segment: green <70, yellow 70-89, red >=90.
seg() { # $1=label $2=pct $3=reset_epoch
  local label="$1" pct="$2" reset="$3" color int
  [ -z "$pct" ] && return
  int="${pct%.*}"
  if   [ "$int" -ge 90 ]; then color=$'\033[31m'
  elif [ "$int" -ge 70 ]; then color=$'\033[33m'
  else                         color=$'\033[32m'
  fi
  # e.g. "5h 62% (2h14m)" — pct now, resets in delta.
  printf '%s%s %s%%%s (%s)' "$color" "$label" "$int" $'\033[0m' "$(fmt_delta "$reset")"
}

rate=""
[ -n "$five" ]  && rate="$rate$(seg 5h "$five" "$five_reset") "
[ -n "$seven" ] && rate="$rate$(seg 7d "$seven" "$seven_reset")"
rate="${rate% }"

if [ -n "$base" ]; then
  printf '%s  ◔ %s\n' "$base" "$rate"
else
  printf '◔ %s\n' "$rate"
fi
