#!/usr/bin/env bash
#
# gitpush-stop-hook.sh — optional auto-commit+push when an agent finishes a turn.
#
# OPT-IN ONLY: this does nothing unless GITPUSH_AUTO=1 is set in the environment.
# It is designed to be wired into Claude Code's `Stop` hook (or a Codex
# equivalent). The harness passes hook JSON on stdin; we don't need it, so we
# just drain it and run gitpush in the current working directory.
#
# ⚠️  WARNING: auto mode runs `git add -A` and pushes UNATTENDED on every turn.
# It will commit anything not covered by .gitignore — including secrets, .env
# files, and build artifacts. Only enable it in repos with a solid .gitignore,
# and never in a repo that holds credentials.
#
# Wire it into Claude Code (~/.claude/settings.json):
#   {
#     "hooks": {
#       "Stop": [
#         { "hooks": [ { "type": "command",
#           "command": "GITPUSH_AUTO=1 bash ~/.claude/skills/gitpush/hooks/gitpush-stop-hook.sh" } ] }
#       ]
#     }
#   }

set -euo pipefail

# Drain stdin (hook payload) without failing if it's empty.
cat >/dev/null 2>&1 || true

# Safety switch: never auto-push unless explicitly enabled.
if [ "${GITPUSH_AUTO:-0}" != "1" ]; then
  exit 0
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../scripts/gitpush.sh"

[ -f "$SCRIPT" ] || { echo "gitpush hook: script not found at $SCRIPT" >&2; exit 0; }

# --auto writes the message with the cheap/low-effort model (falls back to a
# heuristic if unavailable); exits cleanly if there's nothing to do.
bash "$SCRIPT" --auto || true
