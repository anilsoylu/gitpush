# gitpush

[![skills.sh](https://skills.sh/b/anilsoylu/gitpush)](https://skills.sh/anilsoylu/gitpush)

Stage, commit, and push in one step from inside an AI coding agent.

`gitpush` detects whether you're in **Claude Code** or **Codex**, writes a
meaningful, change-specific commit message, and pushes — **with a clean author
identity**.

> No `Co-Authored-By`. No AI profile or avatar on your GitHub commits. The
> commit stays under **your own identity**.

## Install

Via the [skills.sh](https://www.skills.sh) CLI:

```bash
# project-local
npx skills add anilsoylu/gitpush

# or globally for all repos
npx skills add -g anilsoylu/gitpush

# target a specific agent
npx skills add anilsoylu/gitpush --agent claude-code
npx skills add anilsoylu/gitpush --agent codex
```

Repo: <https://github.com/anilsoylu/gitpush>

## Use

Just tell your agent:

> gitpush "feat: add login validation"

or simply **"commit and push"** / **"kaydet ve gönder"**. The skill will:

1. Detect the tool (Claude Code vs Codex) from the environment.
2. `git add -A`.
3. Commit — **no AI signature**. Give exact wording and it's used verbatim;
   say nothing and `--auto` writes a meaningful, change-specific message for you
   (subject + bullet body) at ~zero tokens from your main session.
4. `git push` (sets upstream automatically on the first push).

Run the script directly if you like:

```bash
bash skills/gitpush/scripts/gitpush.sh -m "fix: handle empty cart"
```

### Options

| Flag | Meaning |
| --- | --- |
| `--auto` | Write a detailed message (subject + bullet body) with the cheap/low-effort model (~zero tokens from your main session). |
| `--no-body` | With `--auto`, produce only the subject line. |
| `-m "msg"` | Provide the commit subject yourself. |
| `--no-push` | Commit only. |
| `--deeplink` | **Opt in** to a `claude://` / `codex://` deep-link trailer (off by default). |
| `--coauthor` | **Opt in** to a `Co-Authored-By` trailer (off by default). |
| `--tool claude\|codex` | Force tool detection. |
| `--dry-run` | Preview without changing anything. |

Everything that puts an AI footprint on the commit is **strictly opt-in**.

## Cost / token-efficient mode

Writing a commit message normally makes your main (expensive) agent read the
diff — that burns tokens, especially on big changes. `--auto` offloads it:

```bash
bash skills/gitpush/scripts/gitpush.sh --auto
```

It spawns a **separate, throwaway** call on the cheapest setting of whichever
tool you're in:

- **Claude** → `claude -p --model haiku --effort low` with thinking disabled.
- **Codex** → `codex exec -c model_reasoning_effort=low`.

This runs in its own process and **does not change your interactive session's
model or effort** — your Opus/high-effort session stays exactly as it is. If the
cheap model can't be reached, it falls back to a heuristic message. Tune the
model via `GITPUSH_CLAUDE_MODEL` / `GITPUSH_CODEX_MODEL`.

By default `--auto` writes a **detailed message** — a Conventional-Commits
subject plus a bullet body describing each change:

```
feat: add navigation link for documentation and update ignore files

- Add a documentation link in the site header pointing to docs.launchly.dev
- Exclude the docssite directory in .dockerignore and .gitignore
- Add a navDocs entry to each locale JSON for the new link
```

Pass `--no-body` (or `GITPUSH_BODY=0`) for a single-line subject instead.

### Pick which AI writes the message

`--tool claude|codex` forces the generator regardless of where you're running.
So from a Claude session you can have **Codex** write the commit:

```bash
bash skills/gitpush/scripts/gitpush.sh --auto --tool codex
```

## MCP server (any MCP client)

Prefer a callable tool over a skill file? `mcp/server.js` is a zero-dependency
Node stdio MCP server that exposes a **`gitpush`** tool, so Claude Code, Codex,
Cursor, OpenCode, Windsurf, and other MCP clients can stage + commit + push
directly. The `tool` argument selects the target generator (e.g. call with
`{auto:true, tool:"codex"}`). Per-client config is in
[`skills/gitpush/mcp/README.md`](skills/gitpush/mcp/README.md).

```bash
# Claude Code, for example:
claude mcp add gitpush -- node ~/.claude/skills/gitpush/mcp/server.js
```

## Auto mode (optional)

Want it to commit + push automatically every time the agent finishes? Wire the
opt-in `Stop` hook. It only fires when `GITPUSH_AUTO=1` is set, so it never
runs by accident.

> ⚠️ **Heads up:** auto mode runs `git add -A` and pushes unattended. It commits
> anything not in your `.gitignore` — including `.env` files and secrets. Only
> turn it on in repos with a solid `.gitignore`, never in one holding
> credentials.

**Claude Code** — add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "GITPUSH_AUTO=1 bash ~/.claude/skills/gitpush/hooks/gitpush-stop-hook.sh" } ] }
    ]
  }
}
```

**Codex** — point its session-end / stop hook at the same script with
`GITPUSH_AUTO=1`.

## How tool detection works

- **Claude Code** is detected via `CLAUDECODE=1` / `CLAUDE_CODE_SESSION_ID`.
- Otherwise the agent context is treated as **Codex**; the thread id (used only
  for the optional deep link) is resolved from `~/.codex/sessions/**/rollout-*.jsonl`
  by matching the session's `cwd` to the current repo.
- Override anytime with `--tool claude|codex`.

## Requirements

- `git`
- `python3` (optional — only speeds up Codex thread resolution; there's a pure
  shell fallback).

## Layout

```
gitpush/
└── skills/
    └── gitpush/
        ├── SKILL.md                  # skill definition (skills.sh / Agent Skills format)
        ├── scripts/gitpush.sh        # core: detect → add → commit → push
        └── hooks/gitpush-stop-hook.sh# optional opt-in auto mode
```

## License

[MIT](./LICENSE) © Anil Soylu
