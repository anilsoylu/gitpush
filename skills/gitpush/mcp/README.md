# gitpush MCP server

`server.js` is a zero-dependency Node stdio MCP server that exposes one tool,
**`gitpush`**, wrapping `../scripts/gitpush.sh`. Any MCP-capable client can call
it to stage + commit + push with a clean, AI-signature-free identity — no matter
which agent you're driving.

Requires **Node.js** and **git** on `PATH`.

## The path

Point your client at the absolute path of `server.js`. If you installed the
skill with `npx skills add`, it's inside the install dir, e.g.:

```
~/.claude/skills/gitpush/mcp/server.js
```

Or clone the repo and use `…/skills/gitpush/mcp/server.js`. Replace
`/ABS/PATH/server.js` below with your real path.

## Tool: `gitpush`

| Argument | Type | Meaning |
| --- | --- | --- |
| `message` | string | Commit subject. Omit when using `auto`. |
| `auto` | boolean | Let the cheap/low-effort model write the message. |
| `body` | boolean | With `auto`, include a bullet body (default true). |
| `push` | boolean | Push to the remote after commit. **Default false over MCP** — set `true` to push. |
| `deeplink` | boolean | Add a `claude://`/`codex://` trailer (default false). |
| `coauthor` | boolean | Add a `Co-Authored-By` trailer (default false). |
| `tool` | `"claude"`\|`"codex"` | Force which AI writes the `auto` message (the target). |
| `cwd` | string | Repo directory (defaults to the server's cwd). |
| `dry_run` | boolean | Preview without changing anything. |

Set `tool` to pick the generator — e.g. call with `{auto:true, tool:"codex"}`
to have Codex write the message even from a Claude client.

## Client configuration

### Claude Code

```bash
claude mcp add gitpush -- node /ABS/PATH/server.js
```

### Codex — `~/.codex/config.toml`

```toml
[mcp_servers.gitpush]
command = "node"
args = ["/ABS/PATH/server.js"]
```

### OpenCode — `opencode.json`

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "gitpush": {
      "type": "local",
      "command": ["node", "/ABS/PATH/server.js"],
      "enabled": true
    }
  }
}
```

### Cursor / Windsurf / generic (`mcpServers` map)

`~/.cursor/mcp.json` (or project `.cursor/mcp.json`),
`~/.codeium/windsurf/mcp_config.json`, and most other clients use the same
shape:

```json
{
  "mcpServers": {
    "gitpush": {
      "command": "node",
      "args": ["/ABS/PATH/server.js"]
    }
  }
}
```

### VS Code (GitHub Copilot) — `.vscode/mcp.json`

```json
{
  "servers": {
    "gitpush": { "command": "node", "args": ["/ABS/PATH/server.js"] }
  }
}
```

## Quick manual check

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | node /ABS/PATH/server.js
```

You should see the `initialize` result and the `gitpush` tool definition.
