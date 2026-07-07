# Install instructions for AI agents

You have been given this repository and asked to install **Rate Limit Monitor**
into the user's Claude Code. Do exactly this:

```bash
bash ./install.sh
```

Then tell the user: **"Installed — restart Claude Code to activate it."**

That is the whole task. Do not hand-edit `settings.json` yourself.

## What the script does (so you can explain it if asked)

`install.sh` is safe and idempotent. It:
- verifies `jq` is installed (aborts with a clear message if not),
- backs up `~/.claude/settings.json` (honors `$CLAUDE_CONFIG_DIR`),
- appends the `UserPromptSubmit` guard hook **without removing existing hooks**,
- sets the statusline, **chaining any statusline the user already has** (so their
  current prompt is preserved),
- re-running it makes no further changes.

## Requirements to mention if they fail

- **`jq`** must be on `PATH` (`brew install jq` / `apt-get install -y jq`).
- The usage data only exists on a **paid Claude plan** (Pro/Max/Team/Enterprise)
  and only after the first API response of a session. On API-key/free usage the
  guard simply never blocks (fails open) — that is expected, not a bug.

## Uninstall

```bash
bash ./uninstall.sh
```

Restores the user's original statusline (or removes ours) and drops the guard
hook. Also backs up first.

## Do NOT

- Do not also run `/plugin install` for this after `install.sh` — that would wire
  the guard twice. `install.sh` is the standalone path; the plugin marketplace
  flow in the README is the *alternative* for humans who prefer it.
- Do not edit the shell scripts unless the user asks; configuration is via env
  vars documented in `README.md` (`RLM_THRESHOLD`, `RLM_WINDOWS`, `RLM_OVERRIDE`).
