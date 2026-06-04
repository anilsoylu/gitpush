---
name: gitpush
description: >-
  Stage, commit, and push in one step from inside an AI coding agent. Use when
  the user says "gitpush", "commit and push", "push my changes", "kaydet ve
  gönder", or wants a quick commit+push. Auto-detects whether it is running in
  Claude Code or Codex, writes a meaningful, change-specific commit message, and
  pushes. By design it does NOT add a Co-Authored-By trailer, so no AI profile
  or avatar appears on the commit in GitHub — the commit stays under the user's
  own identity. A Co-Authored-By trailer and a session deep link are opt-in.
---

# gitpush

One command to `git add` + `git commit` + `git push` from inside an AI coding
agent, with a clean author identity and no AI signature.

## What it does

1. Detects the host tool from the environment (Claude Code vs Codex).
2. Stages all changes (`git add -A`).
3. Writes a **meaningful, repo-specific commit message** (you provide it, or let
   `--auto` generate it — see below).
4. Commits **without** a `Co-Authored-By` trailer, so the commit shows up under
   the user's own GitHub identity with no AI profile/avatar attached.
5. Pushes (creates upstream with `-u origin <branch>` on first push).

Both a `Co-Authored-By` trailer and a deep link back to the session/thread are
**opt-in only** (`--coauthor`, `--deeplink`); by default the commit carries
neither, so there is zero AI footprint.

## How to use it

The core logic lives in `scripts/gitpush.sh`. `$SKILL_DIR` below is the
directory containing this SKILL.md (the script ships under `scripts/`).

There are two ways to set the commit message. **Prefer the cheap mode** — it
keeps your (expensive) context clean.

### Cheap mode — `--auto` (recommended, ~zero tokens from you)

Let the script write the message itself using the detected tool's CHEAPEST
model and LOWEST effort (Claude → `haiku` + `--effort low` + thinking off;
Codex → `model_reasoning_effort=low`). You don't read the diff at all:

```bash
bash "$SKILL_DIR/scripts/gitpush.sh" --auto
```

By default this produces a **detailed message** — a Conventional-Commits
subject plus a bullet-point body explaining the changes:

```
feat: add navigation link for documentation and update ignore files

- Add a documentation link in the site header pointing to docs.launchly.dev
- Exclude the docssite directory in .dockerignore and .gitignore
- Add a navDocs entry to each locale JSON for the new link
```

Add `--no-body` for a single-line subject instead. If the cheap model isn't
reachable it falls back to a heuristic message, so it never blocks the commit.

#### Choosing which AI writes the message (target)

By default `--auto` uses whichever tool you're in. To force a different one —
e.g. the user says **"gitpush codex"**, **"gitpush with codex"**, or
**"/gitpush codex"** — pass `--tool` so that tool generates the message even
if you're running inside another agent:

```bash
# You're in Claude, but Codex writes the commit message:
bash "$SKILL_DIR/scripts/gitpush.sh" --auto --tool codex

# Force Claude (haiku) as the generator:
bash "$SKILL_DIR/scripts/gitpush.sh" --auto --tool claude
```

Whenever the user names a tool alongside the gitpush request, treat it as the
target and pass it via `--tool`. The named tool's CLI must be installed; if it
isn't reachable, gitpush falls back to a heuristic message.

### Manual mode — `-m` (when you want exact wording)

If you write the message yourself, **do NOT read the full diff** (it burns
tokens). Look only at `git -C <repo> status --short` and
`git -C <repo> diff --stat`; that's enough for a good subject. Then:

```bash
bash "$SKILL_DIR/scripts/gitpush.sh" -m "feat: add login form validation"
```

Use a concise Conventional-Commits subject (`feat:`, `fix:`, `docs:`, …). Never
use generic messages like "update files".

### Common options

| Flag | Meaning |
| --- | --- |
| `--auto` | Generate a detailed message (subject + bullet body) with the cheap/low-effort model (~zero tokens from you). |
| `--no-body` | With `--auto`, produce only the subject line. |
| `-m "msg"` | Provide the commit subject yourself. |
| `--no-push` | Commit only, do not push. |
| `--deeplink` | Opt IN to a deep-link trailer (off by default). |
| `--coauthor` | Opt IN to a `Co-Authored-By` trailer (off by default). |
| `--tool claude\|codex` | Force tool detection. |
| `--dry-run` | Show what would happen without changing anything. |

Cost knobs (env): `GITPUSH_CLAUDE_MODEL` (default `haiku`),
`GITPUSH_CODEX_MODEL` (default: codex's own config) tune which model `--auto`
uses.

### Defaults that matter

- **No `Co-Authored-By` by default** — this is the whole point: keep the AI
  profile off the commit. Only `--coauthor` (or `GITPUSH_COAUTHOR=1`) adds it.
- **No deep link by default.** Only `--deeplink` (or `GITPUSH_DEEPLINK=1`)
  appends a `claude://`/`codex://` trailer.

## Auto mode (optional hook)

`hooks/gitpush-stop-hook.sh` can auto-commit+push every time the agent finishes
a turn. It is **opt-in** and only runs when `GITPUSH_AUTO=1` is set, so it never
fires by accident. See the repo README for wiring it into Claude Code's `Stop`
hook or Codex's equivalent.

## MCP server (use from any MCP client)

`mcp/server.js` exposes the same behaviour as an MCP tool named `gitpush`, so
MCP-capable clients (Claude Code, Codex, Cursor, OpenCode, Windsurf, …) can call
it directly. It's a zero-dependency Node stdio server that wraps
`scripts/gitpush.sh`. Tool arguments mirror the flags: `message`, `auto`,
`body`, `push`, `deeplink`, `coauthor`, `tool` (target), `cwd`, `dry_run`.
See `mcp/README.md` for per-client config.

## Notes

- If the working tree is clean, the script exits cleanly (code 2) without
  committing.
- If there is no remote or you are on a detached HEAD, it commits but skips the
  push and tells you.
- Requires `git`. Codex thread resolution uses `python3` when available, with a
  shell fallback.
