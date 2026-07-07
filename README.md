# Rate Limit Monitor

**Never get cut off mid-task by your Claude Code usage limits again.**

A tiny [Claude Code](https://code.claude.com) plugin that shows your **5-hour**
and **7-day** usage windows right in the statusline, and — when you're about to
run out — **stops the next prompt** so you don't spend the last of your window
on a long, token-heavy task.

<p align="center">
  <img src="assets/statusline-normal.png" alt="Statusline showing 5h 62% and 7d 41%, both green" width="720">
</p>

Healthy usage: green. It shows the percentage used and a countdown to reset
(`5h 62% (2h14m)`). As you climb it turns yellow at 70%, red at 90%:

<p align="center">
  <img src="assets/statusline-warning.png" alt="Statusline showing 5h at 93% in red, resets in 38m" width="720">
</p>

And the moment you try to kick off new work while ≥90%, the guard steps in — your
session stays completely intact, so you lose no context:

<p align="center">
  <img src="assets/guard-block.png" alt="Guard blocking a prompt at 93% with wait/override options" width="640">
</p>

You choose:

- **Wait** for the window to reset, then resubmit the same prompt — the guard
  **clears itself automatically** once the reset time passes.
- **Continue now** — just include `!limit-ok` anywhere in your message.

---

## Why two pieces?

Claude Code hands the *official* rate-limit numbers (`rate_limits.five_hour.used_percentage`
and `resets_at`) **only to the statusline** — `UserPromptSubmit` hooks never see
them. So the two components cooperate:

```
 ┌─────────────┐  official rate_limits   ┌──────────────────────────┐
 │  Claude Code │ ──────────────────────▶ │  statusline script       │
 └─────────────┘      (every turn)        │  • renders the segment   │
                                          │  • writes state to a file│
                                          └───────────┬──────────────┘
                                                      │ ~/.claude/.rate-limit-state.json
                                                      ▼
                                          ┌──────────────────────────┐
                       your next prompt ─▶│  UserPromptSubmit guard   │
                                          │  reads state → block/allow│
                                          └──────────────────────────┘
```

No transcript parsing, no token estimation — it's the real number, straight from
Anthropic.

## Requirements

- **A subscription plan** (Pro / Max / Team / Enterprise). The `rate_limits` data
  only exists on those plans, and only *after* the first API response of a
  session. Before that (and for API-key users) the guard simply allows
  everything — it fails **open**, never blocks you by mistake.
- **`jq`** on your `PATH` (`brew install jq` / `apt install jq`).

## Install

### 1. The guard hook — via the plugin

```
/plugin marketplace add <your-github-user>/rate-limit-monitor
/plugin install rate-limit-monitor@rate-limit-monitor
```

Installing the plugin auto-wires the `UserPromptSubmit` guard. For local
development you can instead launch Claude Code with
`--plugin-dir /path/to/rate-limit-monitor`.

### 2. The statusline — one line in your settings

Plugins can't ship a statusline, so add it yourself in `~/.claude/settings.json`.
To **keep your existing statusline**, chain it via `RLM_INNER_STATUSLINE`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "RLM_INNER_STATUSLINE='bash ~/.claude/statusline-command.sh' bash /ABS/PATH/rate-limit-monitor/statusline/rate-limit-statusline.sh"
  }
}
```

If you don't already have a statusline, drop the `RLM_INNER_STATUSLINE=...` prefix.

> Restart Claude Code after editing settings — statusline and hooks are read at
> session start.

## Configuration

Everything is tuned with environment variables (set them inline in the statusline
command, or export them in your shell profile):

| Variable               | Default                             | Meaning                                            |
| ---------------------- | ----------------------------------- | -------------------------------------------------- |
| `RLM_THRESHOLD`        | `90`                                | Block at/above this percent.                       |
| `RLM_OVERRIDE`         | `!limit-ok`                         | Phrase in a prompt that forces it through.         |
| `RLM_WINDOWS`          | `both`                              | Which windows guard: `5h`, `7d`, or `both`.        |
| `RLM_STATE_FILE`       | `~/.claude/.rate-limit-state.json`  | Shared state file (statusline ↔ hook).             |
| `RLM_INNER_STATUSLINE` | *(none)*                            | A statusline command to render before this one.    |

## How the guard behaves

- It fires on **prompt submit**, not mid-run. It's a checkpoint before you start
  new work — it can't (and shouldn't) interrupt a task already executing.
- A hook can't pop an interactive dialog, so the block message *is* the question:
  wait, or override with the phrase.
- Once the clock passes the window's `resets_at`, the stored reading is treated as
  stale and you're allowed through — so "wait then continue" needs no manual step.

## License

MIT © meital
