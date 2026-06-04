#!/usr/bin/env node
/*
 * gitpush MCP server — exposes the `gitpush` tool over the Model Context
 * Protocol (stdio transport, newline-delimited JSON-RPC 2.0) so ANY MCP client
 * (Claude Code, Codex, Cursor, OpenCode, Windsurf, generic) can stage + commit
 * + push with a clean, AI-signature-free identity.
 *
 * Zero dependencies — just `node server.js`. It shells out to the sibling
 * scripts/gitpush.sh, so all behaviour (tool detection, --auto cheap message,
 * no Co-Authored-By by default) is shared with the CLI/skill.
 *
 * Logs go to stderr ONLY; stdout carries protocol messages exclusively.
 */
"use strict";

const path = require("path");
const { spawnSync } = require("child_process");

const SCRIPT = path.join(__dirname, "..", "scripts", "gitpush.sh");
const PROTOCOL_VERSION = "2025-06-18";
const SERVER_INFO = { name: "gitpush", version: "1.0.0" };

const TOOL = {
  name: "gitpush",
  description:
    "Stage all changes, commit, and push from the current git repository, " +
    "with a clean author identity (NO Co-Authored-By, no AI profile on " +
    "GitHub). Provide `message` for the commit subject, OR set `auto:true` to " +
    "have a cheap local model write a detailed message. Auto-detects Claude " +
    "Code vs Codex for the optional session deep link.",
  inputSchema: {
    type: "object",
    properties: {
      message: {
        type: "string",
        description:
          "Commit subject (Conventional Commits style). Omit when using `auto`.",
      },
      auto: {
        type: "boolean",
        description:
          "Generate the commit message with the detected tool's cheapest, " +
          "lowest-effort model instead of `message`. Default false.",
      },
      body: {
        type: "boolean",
        description:
          "With `auto`, include a bullet-point body (default true). Set false " +
          "for a single-line subject.",
      },
      push: {
        type: "boolean",
        description: "Push after committing. Default true.",
      },
      deeplink: {
        type: "boolean",
        description:
          "Add a claude://|codex:// session deep-link trailer. Default false.",
      },
      coauthor: {
        type: "boolean",
        description:
          "Add a Co-Authored-By trailer (makes the AI profile show up on " +
          "GitHub). Default false.",
      },
      tool: {
        type: "string",
        enum: ["claude", "codex"],
        description: "Force tool detection instead of auto-detecting.",
      },
      cwd: {
        type: "string",
        description:
          "Absolute path to the git repository to operate in. Defaults to the " +
          "server's working directory.",
      },
      dry_run: {
        type: "boolean",
        description: "Preview the actions without changing anything.",
      },
    },
    additionalProperties: false,
  },
};

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function result(id, res) {
  send({ jsonrpc: "2.0", id, result: res });
}

function error(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function runGitpush(args) {
  const a =
    args && typeof args === "object" && !Array.isArray(args) ? args : {};
  const argv = [SCRIPT];

  if (typeof a.message === "string" && a.message.trim()) {
    argv.push("-m", a.message);
  }
  if (a.auto === true) argv.push("--auto");
  if (a.body === false) argv.push("--no-body");
  if (a.body === true) argv.push("--body");
  if (a.push === false) argv.push("--no-push");
  if (a.deeplink === true) argv.push("--deeplink");
  if (a.coauthor === true) argv.push("--coauthor");
  if (a.tool === "claude" || a.tool === "codex") argv.push("--tool", a.tool);
  if (a.dry_run === true) argv.push("--dry-run");

  const cwd =
    typeof a.cwd === "string" && a.cwd.trim() ? a.cwd : process.cwd();

  const r = spawnSync("bash", argv, {
    cwd,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 10 * 1024 * 1024,
  });

  const out = `${r.stdout || ""}${r.stderr || ""}`.trim() || "(no output)";
  // Exit 0 = committed, 2 = nothing to commit — both are non-error outcomes.
  const isError = r.status !== 0 && r.status !== 2;
  return { text: out, isError };
}

function handle(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return; // ignore non-JSON / partial noise
  }
  if (!msg || typeof msg !== "object") return;

  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;

  switch (method) {
    case "initialize": {
      const pv =
        params && typeof params.protocolVersion === "string"
          ? params.protocolVersion
          : PROTOCOL_VERSION;
      result(id, {
        protocolVersion: pv,
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
      });
      return;
    }
    case "tools/list":
      result(id, { tools: [TOOL] });
      return;
    case "tools/call": {
      const name = params && params.name;
      if (name !== TOOL.name) {
        if (isRequest) error(id, -32602, `Unknown tool: ${name}`);
        return;
      }
      let out;
      try {
        out = runGitpush(params && params.arguments);
      } catch (e) {
        out = { text: `gitpush MCP error: ${e && e.message}`, isError: true };
      }
      result(id, {
        content: [{ type: "text", text: out.text }],
        isError: out.isError,
      });
      return;
    }
    case "ping":
      result(id, {});
      return;
    default:
      // Notifications (no id) like notifications/initialized: ignore silently.
      if (isRequest) error(id, -32601, `Method not found: ${method}`);
      return;
  }
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (line) handle(line);
  }
});
process.stdin.on("end", () => process.exit(0));
