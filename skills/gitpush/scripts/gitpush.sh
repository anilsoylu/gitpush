#!/usr/bin/env bash
#
# gitpush.sh — the terminal equivalent of the "AI commit message" button in
# Cursor/VSCode. Auto-detects the running AI coding tool (Claude Code or Codex),
# stages everything, writes a clean commit (NO Co-Authored-By, NO AI profile on
# GitHub), and pushes.
#
# Usage:
#   gitpush.sh [options] [-- commit subject...]
#   gitpush.sh -m "feat: add login flow"
#
# Options:
#   -m, --message MSG   Commit subject (otherwise auto-generated from changes).
#   -n, --no-push       Commit only, skip push.
#   -a, --no-add        Do not run `git add -A` (commit what's already staged).
#       --deeplink      ADD a deep-link trailer back to the session/thread
#                       (off by default — keeps commits clean like Cursor/VSCode).
#       --coauthor      ADD a Co-Authored-By trailer (off by default, since it
#                       makes the AI profile/avatar show up on GitHub).
#       --tool TOOL     Force tool detection: claude | codex.
#       --dry-run       Print what would happen without changing anything.
#   -h, --help          Show this help.
#
# Environment overrides:
#   GITPUSH_TOOL          Same as --tool.
#   GITPUSH_DEEPLINK=1    Same as --deeplink.
#   GITPUSH_COAUTHOR=1    Same as --coauthor.
#
# By default there is NO Co-Authored-By and NO deep link: the commit is clean and
# stays under your own identity, so no AI profile/avatar shows up on GitHub.
# Both extras are strictly opt-in.
#
# Exit codes: 0 ok / committed, 2 nothing to commit, 1 error.

set -euo pipefail

say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'gitpush: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then say "DRY: $*"; else "$@"; fi; }

# ---------- args ----------
MESSAGE=""
DO_PUSH=1
DO_ADD=1
DRY_RUN=0
ADD_DEEPLINK="${GITPUSH_DEEPLINK:-0}"
ADD_COAUTHOR="${GITPUSH_COAUTHOR:-0}"
FORCE_TOOL="${GITPUSH_TOOL:-}"

print_help() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message) [ $# -ge 2 ] || die "$1 requires a value"; MESSAGE="$2"; shift 2;;
    -n|--no-push) DO_PUSH=0; shift;;
    -a|--no-add)  DO_ADD=0; shift;;
    --deeplink)    ADD_DEEPLINK=1; shift;;
    --no-deeplink) ADD_DEEPLINK=0; shift;;
    --coauthor)   ADD_COAUTHOR=1; shift;;
    --tool)       [ $# -ge 2 ] || die "--tool requires a value"; FORCE_TOOL="$2"; shift 2;;
    --dry-run)    DRY_RUN=1; shift;;
    -h|--help)    print_help; exit 0;;
    --)           shift; MESSAGE="${MESSAGE:+$MESSAGE }$*"; break;;
    *)            MESSAGE="${MESSAGE:+$MESSAGE }$1"; shift;;
  esac
done

command -v git >/dev/null 2>&1 || die "git not found on PATH"

# ---------- locate repo ----------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "not inside a git repository (cd into your repo, or run: git init)"
fi
REPO_ROOT="$(git rev-parse --show-toplevel)"

# ---------- tool detection ----------
detect_tool() {
  if [ -n "$FORCE_TOOL" ]; then printf '%s' "$FORCE_TOOL"; return; fi
  if [ "${CLAUDECODE:-}" = "1" ] || [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf 'claude'; return
  fi
  # Anything else running this from an agent context is treated as Codex.
  printf 'codex'
}

# ---------- session/thread id resolution ----------
resolve_claude_id() {
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_CODE_SESSION_ID"; return 0
  fi
  # Fallback: newest transcript for this repo. Claude encodes cwd by
  # replacing every non-alphanumeric char with '-'.
  local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  local enc; enc="$(printf '%s' "$REPO_ROOT" | sed 's/[^a-zA-Z0-9]/-/g')"
  local dir="$base/$enc"
  # On case-insensitive filesystems the encoded path may differ in case from
  # the real directory (e.g. Documents vs documents) — match case-insensitively.
  if [ ! -d "$dir" ]; then
    dir="$(find "$base" -maxdepth 1 -type d -iname "$enc" 2>/dev/null | head -1)"
    [ -n "$dir" ] || return 1
  fi
  local f; f="$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)" || return 1
  [ -n "$f" ] || return 1
  basename "$f" .jsonl
}

resolve_codex_id() {
  local home="${CODEX_HOME:-$HOME/.codex}"
  local sessions="$home/sessions"
  [ -d "$sessions" ] || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$sessions" "$REPO_ROOT" <<'PY' 2>/dev/null && return 0
import os, sys, json, glob
sessions, repo = sys.argv[1], os.path.realpath(sys.argv[2]).lower()
files = sorted(glob.glob(os.path.join(sessions, "**", "rollout-*.jsonl"),
                         recursive=True), reverse=True)
for f in files[:800]:
    try:
        with open(f, "r", errors="ignore") as fh:
            meta = json.loads(fh.readline())
    except Exception:
        continue
    if meta.get("type") != "session_meta":
        continue
    p = meta.get("payload", {})
    if os.path.realpath(p.get("cwd", "")).lower() == repo:
        print(p.get("id", "")); sys.exit(0)
sys.exit(1)
PY
    return 1
  fi

  # Pure-shell fallback: match cwd in the first line, take uuid from filename.
  local f first id
  while IFS= read -r f; do
    first="$(head -n1 "$f" 2>/dev/null || true)"
    case "$first" in
      *"\"cwd\":\"$REPO_ROOT\""*)
        id="$(basename "$f" | sed -E 's/.*-([0-9a-f-]{36})\.jsonl$/\1/')"
        printf '%s' "$id"; return 0;;
    esac
  done < <(find "$sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null | sort -r | head -800)
  return 1
}

TOOL="$(detect_tool)"
DEEPLINK=""
TOOL_LABEL=""
COAUTHOR=""

case "$TOOL" in
  claude)
    TOOL_LABEL="Claude Code"
    COAUTHOR="Co-Authored-By: Claude <noreply@anthropic.com>"
    if [ "$ADD_DEEPLINK" = "1" ] && SID="$(resolve_claude_id)"; then
      DEEPLINK="claude://resume?session=$SID"
    fi
    ;;
  codex)
    TOOL_LABEL="Codex"
    COAUTHOR="Co-Authored-By: Codex <noreply@openai.com>"
    if [ "$ADD_DEEPLINK" = "1" ] && SID="$(resolve_codex_id)"; then
      DEEPLINK="codex://threads/$SID"
    fi
    ;;
  *)
    die "unknown tool '$TOOL' (use --tool claude|codex)"
    ;;
esac

# ---------- stage ----------
if [ "$DO_ADD" = 1 ]; then
  run git -C "$REPO_ROOT" add -A
fi

# What will actually be committed? In a real run we inspect the index; in a
# dry-run with --add the `add -A` was only simulated, so preview the working
# tree instead (otherwise we'd wrongly report "nothing to commit").
if [ "$DO_ADD" = 1 ] && [ "$DRY_RUN" = 1 ]; then
  CHANGED="$(git -C "$REPO_ROOT" status --porcelain | sed 's/^...//')"
else
  CHANGED="$(git -C "$REPO_ROOT" diff --cached --name-only)"
fi

if [ -z "$CHANGED" ]; then
  say "gitpush: nothing to commit, working tree clean"
  [ "$DRY_RUN" = 1 ] && exit 0
  exit 2
fi

# ---------- build commit message ----------
if [ -z "$MESSAGE" ]; then
  COUNT="$(printf '%s\n' "$CHANGED" | grep -c .)"
  FILES="$(printf '%s\n' "$CHANGED" | head -3 \
    | awk 'NR>1{printf ", "} {printf "%s", $0} END{print ""}')"
  [ "$COUNT" -gt 3 ] && FILES="$FILES, …"
  MESSAGE="chore: update $COUNT file(s) — $FILES"
fi

BODY=""
add_line() { BODY="${BODY:+$BODY
}$1"; }

# Deep link is OFF by default — clean commits like Cursor/VSCode.
if [ "$ADD_DEEPLINK" = "1" ] && [ -n "$DEEPLINK" ]; then
  case "$TOOL" in
    claude) add_line "Claude-Session: $DEEPLINK";;
    codex)  add_line "Codex-Thread: $DEEPLINK";;
  esac
fi
# Co-Authored-By is OFF by default so no AI profile shows up on GitHub.
if [ "$ADD_COAUTHOR" = "1" ] && [ -n "$COAUTHOR" ]; then
  add_line "$COAUTHOR"
fi

say "gitpush: tool=$TOOL_LABEL  link=${DEEPLINK:-<none>}"
say "gitpush: message=\"$MESSAGE\""

if [ -n "$BODY" ]; then
  run git -C "$REPO_ROOT" commit -m "$MESSAGE" -m "$BODY"
else
  run git -C "$REPO_ROOT" commit -m "$MESSAGE"
fi

# ---------- push ----------
if [ "$DO_PUSH" = 1 ]; then
  if ! git -C "$REPO_ROOT" remote | grep -q .; then
    say "gitpush: no remote configured — committed but not pushed"
    exit 0
  fi
  BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD || true)"
  if [ -z "$BRANCH" ]; then
    say "gitpush: detached HEAD — committed but not pushed"
    exit 0
  fi
  if git -C "$REPO_ROOT" rev-parse --abbrev-ref "@{u}" >/dev/null 2>&1; then
    run git -C "$REPO_ROOT" push
  else
    # No upstream yet: use the branch's configured remote, else the first
    # remote (don't assume it's named "origin").
    REMOTE="$(git -C "$REPO_ROOT" config "branch.$BRANCH.remote" 2>/dev/null || true)"
    [ -n "$REMOTE" ] || REMOTE="$(git -C "$REPO_ROOT" remote | head -1)"
    run git -C "$REPO_ROOT" push -u "$REMOTE" "$BRANCH"
  fi
fi

say "gitpush: done"
