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
const { spawn } = require("child_process");

const SCRIPT = path.join(__dirname, "..", "scripts", "gitpush.sh");
const PROTOCOL_VERSION = "2025-06-18";
const SUPPORTED_PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const SERVER_INFO = { name: "gitpush", version: "1.0.0" };
const RUN_TIMEOUT_MS = 120000;
const MAX_OUTPUT = 10 * 1024 * 1024;

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
        description:
          "Push after committing. Default FALSE over MCP — set true to push " +
          "to the remote (commits stay local otherwise).",
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
  // Push is OPT-IN over MCP: only push when the caller explicitly asks.
  if (a.push !== true) argv.push("--no-push");
  if (a.deeplink === true) argv.push("--deeplink");
  if (a.coauthor === true) argv.push("--coauthor");
  if (a.tool === "claude" || a.tool === "codex") argv.push("--tool", a.tool);
  if (a.dry_run === true) argv.push("--dry-run");

  const cwd =
    typeof a.cwd === "string" && a.cwd.trim() ? a.cwd : process.cwd();

  // Async spawn so the stdio event loop is never blocked during a slow --auto.
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn("bash", argv, { cwd });
    } catch (e) {
      resolve({ text: `gitpush: failed to start (${e && e.message})`, isError: true });
      return;
    }

    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const cap = (buf, chunk) =>
      buf.length < MAX_OUTPUT ? buf + chunk : buf;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, RUN_TIMEOUT_MS);

    child.stdout.on("data", (d) => (stdout = cap(stdout, d)));
    child.stderr.on("data", (d) => (stderr = cap(stderr, d)));

    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ text: `gitpush: failed to run (${e && e.message})`, isError: true });
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      let text = `${stdout}${stderr}`.trim();
      if (timedOut) {
        text = `${text ? text + "\n" : ""}gitpush: timed out after ${RUN_TIMEOUT_MS / 1000}s`;
      }
      text = text || "(no output)";
      // Exit 0 = committed, 2 = nothing to commit — both are non-error outcomes.
      const isError = timedOut || (code !== 0 && code !== 2);
      resolve({ text, isError });
    });
  });
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
      // Echo the client's version only if we actually support it; otherwise
      // advertise our own latest (per the MCP lifecycle spec).
      const req = params && params.protocolVersion;
      const pv = SUPPORTED_PROTOCOLS.includes(req) ? req : PROTOCOL_VERSION;
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
      // Never run side effects (commit/push) for a notification — a request
      // MUST carry an id. This blocks id-less calls from mutating the repo.
      if (!isRequest) return;
      const name = params && params.name;
      if (name !== TOOL.name) {
        error(id, -32602, `Unknown tool: ${name}`);
        return;
      }
      pending++;
      runGitpush(params && params.arguments)
        .then((out) =>
          result(id, {
            content: [{ type: "text", text: out.text }],
            isError: out.isError,
          })
        )
        .catch((e) =>
          result(id, {
            content: [{ type: "text", text: `gitpush MCP error: ${e && e.message}` }],
            isError: true,
          })
        )
        .finally(() => {
          pending--;
          maybeExit();
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

// Track in-flight tool calls so we don't exit (when the client closes stdin
// during shutdown) until any running commit/push has finished and replied.
let pending = 0;
let stdinEnded = false;
function maybeExit() {
  if (stdinEnded && pending === 0) process.exit(0);
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
process.stdin.on("end", () => {
  stdinEnded = true;
  maybeExit();
});
