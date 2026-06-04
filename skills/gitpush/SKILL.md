---
name: gitpush
description: >-
  Stage, commit, and push in one step from inside an AI coding agent — the
  terminal equivalent of the "AI commit message" feature in Cursor/VSCode, so
  you don't have to keep a RAM-heavy GUI editor open just to generate commits.
  Use when the user says "gitpush", "commit and push", "push my changes",
  "kaydet ve gönder", or wants a quick commit+push. Auto-detects whether it is
  running in Claude Code or Codex, writes a meaningful, change-specific commit
  message, and pushes. By design it does NOT add a Co-Authored-By trailer, so no
  AI profile or avatar appears on the commit in GitHub — the commit stays clean
  under the user's own identity, exactly like Cursor/VSCode commits do.
---

# gitpush

One command to `git add` + `git commit` + `git push` from inside an AI coding
agent — a clean, AI-signature-free commit, like the "Generate commit message"
button in Cursor/VSCode but without keeping those editors open.

## What it does

1. Detects the host tool from the environment (Claude Code vs Codex).
2. Stages all changes (`git add -A`).
3. Writes a **meaningful, repo-specific commit message** (you provide it — see
   below).
4. Commits **without** a `Co-Authored-By` trailer, so the commit shows up under
   the user's own GitHub identity with no AI profile/avatar attached — exactly
   like commits made through Cursor/VSCode.
5. Pushes (creates upstream with `-u origin <branch>` on first push).

Both a `Co-Authored-By` trailer and a deep link back to the session/thread are
**opt-in only** (`--coauthor`, `--deeplink`); by default the commit carries
neither, so there is zero AI footprint.

## How to use it

The core logic lives in `scripts/gitpush.sh`. Always pass a real, descriptive
commit message — generate it yourself from the actual diff. Do NOT use generic
messages like "update files".

**Steps for the agent:**

1. Review what changed: `git -C <repo> status --short` and
   `git -C <repo> diff --stat` (and the diff itself for context).
2. Compose a concise Conventional-Commits style subject that describes the
   change (e.g. `feat: add login form validation`, `fix: handle empty cart`).
3. Run the script with that message:

```bash
bash "$SKILL_DIR/scripts/gitpush.sh" -m "feat: add login form validation"
```

`$SKILL_DIR` is the directory containing this SKILL.md. If unsure of the path,
locate the script first (it is shipped alongside this file under `scripts/`).

### Common options

| Flag | Meaning |
| --- | --- |
| `-m "msg"` | Commit subject (required for good messages). |
| `--no-push` | Commit only, do not push. |
| `--deeplink` | Opt IN to a deep-link trailer (off by default). |
| `--coauthor` | Opt IN to a `Co-Authored-By` trailer (off by default). |
| `--tool claude\|codex` | Force tool detection. |
| `--dry-run` | Show what would happen without changing anything. |

### Defaults that matter

- **No `Co-Authored-By` by default** — this is the whole point: keep the AI
  profile off the commit. Only `--coauthor` (or `GITPUSH_COAUTHOR=1`) adds it.
- **No deep link by default** — clean commits like Cursor/VSCode. Only
  `--deeplink` (or `GITPUSH_DEEPLINK=1`) appends a `claude://`/`codex://`
  trailer.

## Auto mode (optional hook)

`hooks/gitpush-stop-hook.sh` can auto-commit+push every time the agent finishes
a turn. It is **opt-in** and only runs when `GITPUSH_AUTO=1` is set, so it never
fires by accident. See the repo README for wiring it into Claude Code's `Stop`
hook or Codex's equivalent.

## Notes

- If the working tree is clean, the script exits cleanly (code 2) without
  committing.
- If there is no remote or you are on a detached HEAD, it commits but skips the
  push and tells you.
- Requires `git`. Codex thread resolution uses `python3` when available, with a
  shell fallback.
