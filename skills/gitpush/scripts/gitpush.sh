#!/usr/bin/env bash
#
# gitpush.sh — stage, commit, and push in one step from inside an AI coding
# agent. Auto-detects the running tool (Claude Code or Codex), stages
# everything, writes a clean commit (NO Co-Authored-By, NO AI profile on
# GitHub), and pushes.
#
# Usage:
#   gitpush.sh [options] [-- commit subject...]
#   gitpush.sh -m "feat: add login flow"
#
# Options:
#   -m, --message MSG   Commit subject (otherwise auto-generated from changes).
#       --auto          Generate the commit message with the detected tool's
#                       CHEAPEST setting (Claude -> haiku model + low effort,
#                       Codex -> low reasoning effort) so the main/expensive
#                       agent spends ~zero tokens. By default this produces a
#                       detailed message (subject + bullet body). Falls back to
#                       a heuristic subject if the cheap model isn't available.
#       --no-body       With --auto, produce only the subject line (no bullets).
#       --body          With --auto, force the detailed bullet body (default).
#   -n, --no-push       Commit only, skip push.
#   -a, --no-add        Do not run `git add -A` (commit what's already staged).
#       --deeplink      ADD a deep-link trailer back to the session/thread
#                       (off by default).
#       --coauthor      ADD a Co-Authored-By trailer (off by default, since it
#                       makes the AI profile/avatar show up on GitHub).
#       --tool TOOL     Force tool detection: claude | codex.
#       --dry-run       Print what would happen without changing anything.
#   -h, --help          Show this help.
#
# Environment overrides:
#   GITPUSH_TOOL          Same as --tool.
#   GITPUSH_AUTO_MSG=1    Same as --auto.
#   GITPUSH_BODY=0        Same as --no-body (default 1 = detailed body).
#   GITPUSH_CLAUDE_MODEL  Model for --auto under Claude (default: haiku).
#   GITPUSH_CODEX_MODEL   Model for --auto under Codex (default: codex's config).
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
AUTO_MSG="${GITPUSH_AUTO_MSG:-0}"
WANT_BODY="${GITPUSH_BODY:-1}"
ADD_DEEPLINK="${GITPUSH_DEEPLINK:-0}"
ADD_COAUTHOR="${GITPUSH_COAUTHOR:-0}"
FORCE_TOOL="${GITPUSH_TOOL:-}"

print_help() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message) [ $# -ge 2 ] || die "$1 requires a value"; MESSAGE="$2"; shift 2;;
    --auto)       AUTO_MSG=1; shift;;
    --no-body)    WANT_BODY=0; shift;;
    --body)       WANT_BODY=1; shift;;
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
        # Only accept a real UUID; on a sed no-match the basename passes
        # through unchanged, which must not become a bogus deeplink.
        case "$id" in
          [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*)
            printf '%s' "$id"; return 0;;
        esac
        ;;
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

# ---------- cheap, low-effort commit-message generator (--auto) ----------
# Generates a Conventional-Commits subject using the detected tool's CHEAPEST
# model AND lowest effort/thinking, so the expensive interactive agent spends
# ~zero tokens. Prints the subject; returns non-zero to fall back to heuristics.
generate_message() {
  local stat diff full body_rule prompt raw subject bullets
  stat="$(git -C "$REPO_ROOT" diff --cached --stat 2>/dev/null || true)"
  full="$(git -C "$REPO_ROOT" diff --cached 2>/dev/null || true)"
  diff="$(printf '%s\n' "$full" | head -500)"
  # Tell the model when the diff was cut, so it describes only what it sees.
  [ "$(printf '%s\n' "$full" | wc -l)" -gt 500 ] && diff="$diff
... [diff truncated]"
  [ -n "$stat" ] || return 1

  if [ "$WANT_BODY" = 1 ]; then
    body_rule="Then a blank line, then 1-5 bullet points (each starting with '- ') describing WHAT changed and WHY where it's obvious; reference file or directory names where helpful. For a trivial one-line change a single bullet is fine."
  else
    body_rule="Do NOT add a body — output only the single subject line."
  fi

  prompt="Write a git commit message in Conventional Commits style for the staged changes below.
First line: a type + ': ' + a concise summary; max 72 chars, lowercase type, no trailing period, no quotes.
Pick the MOST SPECIFIC type from: feat (new capability), fix (bug fix), docs, style, refactor (behaviour-preserving restructure ONLY), perf, test, build, ci, chore, revert. If new code adds behaviour it is feat, not refactor; if it corrects wrong behaviour it is fix.
Use imperative present tense ('add', 'remove', 'replace', 'rename', 'guard', 'validate'). Describe WHAT the diff actually changes — never vague filler like 'improve', 'update', 'enhance', 'various', 'changes', 'misc', or 'readability'.
$body_rule
The diff may be truncated; describe only changes you can see and do not overstate scope ('comprehensive', 'various') for parts you cannot see.
Output ONLY the commit message — no markdown fences, no preamble, no quotes.

=== files (git diff --stat) ===
$stat

=== diff (may be truncated) ===
$diff"

  case "$TOOL" in
    claude)
      command -v claude >/dev/null 2>&1 || return 1
      # haiku model + low effort + thinking disabled.
      raw="$(printf '%s' "$prompt" | MAX_THINKING_TOKENS=0 claude -p \
        --model "${GITPUSH_CLAUDE_MODEL:-haiku}" --effort low 2>/dev/null || true)"
      ;;
    codex)
      command -v codex >/dev/null 2>&1 || return 1
      # low reasoning effort; optional cheaper model via GITPUSH_CODEX_MODEL.
      local -a cx=(codex exec --skip-git-repo-check -c model_reasoning_effort=low)
      [ -n "${GITPUSH_CODEX_MODEL:-}" ] && cx+=(-m "$GITPUSH_CODEX_MODEL")
      raw="$(printf '%s' "$prompt" | "${cx[@]}" 2>/dev/null || true)"
      ;;
    *) return 1;;
  esac

  # Subject = first Conventional-Commits-looking line (skips any log/preamble).
  subject="$(printf '%s\n' "$raw" \
    | grep -m1 -iE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?: .+' \
    || true)"
  # If the model emitted no recognised type, take its first non-empty line —
  # still better than the generic "chore: update N files" heuristic.
  [ -n "$subject" ] || subject="$(printf '%s\n' "$raw" \
    | grep -m1 -E '[^[:space:]]' | sed -E 's/^[[:space:]]+//' || true)"
  subject="${subject:0:100}"   # character-safe cap (avoids splitting UTF-8)
  [ -n "$subject" ] || return 1

  # Body = the bullet lines anywhere in the output, normalised to "- ".
  if [ "$WANT_BODY" = 1 ]; then
    bullets="$(printf '%s\n' "$raw" \
      | grep -E '^[[:space:]]*[-*][[:space:]]+[^[:space:]]' \
      | sed -E 's/^[[:space:]]*[-*][[:space:]]+/- /' \
      | head -8 || true)"
  fi

  # Caller reads line 1 as the subject and the rest as the body.
  printf '%s\n' "$subject"
  [ -n "${bullets:-}" ] && printf '%s\n' "$bullets"
  return 0
}

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
MSG_BODY=""   # optional descriptive body (bullets) from --auto
if [ -z "$MESSAGE" ]; then
  if [ "$AUTO_MSG" = 1 ] && GEN="$(generate_message)"; then
    MESSAGE="$(printf '%s\n' "$GEN" | head -1)"
    MSG_BODY="$(printf '%s\n' "$GEN" | tail -n +2 | sed '/^[[:space:]]*$/d')"
    say "gitpush: auto-message via $TOOL_LABEL (cheap model, low effort)"
  else
    [ "$AUTO_MSG" = 1 ] && say "gitpush: --auto unavailable, using heuristic message"
    COUNT="$(printf '%s\n' "$CHANGED" | grep -c .)"
    FILES="$(printf '%s\n' "$CHANGED" | head -3 \
      | awk 'NR>1{printf ", "} {printf "%s", $0} END{print ""}')"
    [ "$COUNT" -gt 3 ] && FILES="$FILES, …"
    MESSAGE="chore: update $COUNT file(s) — $FILES"
  fi
fi

# Trailers (deep link / co-author) — both opt-in, off by default.
TRAILERS=""
add_line() { TRAILERS="${TRAILERS:+$TRAILERS
}$1"; }

# Deep link is OFF by default.
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

# Each -m becomes its own paragraph: subject / body bullets / trailers.
COMMIT_ARGS=(commit -m "$MESSAGE")
[ -n "$MSG_BODY" ]  && COMMIT_ARGS+=(-m "$MSG_BODY")
[ -n "$TRAILERS" ]  && COMMIT_ARGS+=(-m "$TRAILERS")
run git -C "$REPO_ROOT" "${COMMIT_ARGS[@]}"

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
