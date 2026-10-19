#!/usr/bin/env bash
# cross-project-transfer.sh — hand a file from one project to another in one call (CFG-427)
#
# Usage:
#   cross-project-transfer.sh <source-file> <target-dir> [--replace-with-pointer]
#       [--summary "<text>"] [--type work|fact|fyi|rule] [--priority P0..P3]
#       [--project <registry-name>] [--no-commit] [--dry-run]
#   afleet transfer <same arguments>
#
#   <target-dir>  the target project's root (file lands in its docs/) or any directory
#                 inside it (used as given; created if missing)
#
# What it does, in this order — each step only after the previous one succeeded:
#   0. refuses if the target project — or, with --replace-with-pointer, the source — has a
#      live Claude Code session other than the caller's own (boundary rule; needs /proc),
#      and, run from a session, when it can see no CC process to tell (sandboxed PID namespace)
#   1. copies the file into the target project (never over an existing file)
#   2. --replace-with-pointer: rewrites the source as a stub naming the canonical
#      location and carrying the summary (documents only: .md / .txt)
#   3. unless --no-commit: stages each path and runs secret-commit-guard.sh on that repo's
#      staged diff — the scan a hand-typed `git commit` gets from the PreToolUse hook,
#      which cannot see commits made inside this script. A hit (or no guard) rolls back
#      1-2: nothing is copied, stubbed, filed or committed.
#   4. files ONE typed inbox item for the target via inbox-file.sh, with an automatic
#      description (title, size, summary, where it came from); if the target is not a
#      registered project the item is refused and 1-3 are rolled back
#   5. commits exactly the transferred path in each repo (`git commit -- <path>`, so
#      another session's staged work is never swept in) — the target first, so the
#      source is only stubbed in history once the canonical copy is committed
#
# Why: the manual read → copy → replace → inbox → commit dance cost ~15 tool calls for a
# single transfer. This is 0-token bash.
set -euo pipefail

_repo_root() { cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd; }
REPO_ROOT="$(_repo_root)"
REGISTRY="$REPO_ROOT/registry.md"
INBOX_FILE_SH="$REPO_ROOT/setup/scripts/inbox-file.sh"
COMMIT_GUARD="$REPO_ROOT/global/hooks/secret-commit-guard.sh"

die() { echo "cross-project-transfer: $*" >&2; exit 2; }
usage() { sed -n '2,32p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'; }

SRC="" TARGET="" POINTER=0 SUMMARY="" TYPE="work" PRIORITY="P2" PROJECT="" COMMIT=1 DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --replace-with-pointer) POINTER=1; shift ;;
        --summary)  [[ $# -ge 2 ]] || die "--summary needs a value"; SUMMARY="$2"; shift 2 ;;
        --type)     [[ $# -ge 2 ]] || die "--type needs a value"; TYPE="$2"; shift 2 ;;
        --priority) [[ $# -ge 2 ]] || die "--priority needs a value"; PRIORITY="$2"; shift 2 ;;
        --project)  [[ $# -ge 2 ]] || die "--project needs a value"; PROJECT="$2"; shift 2 ;;
        --no-commit) COMMIT=0; shift ;;
        --dry-run)  DRY=1; shift ;;
        -*) die "unknown option: $1" ;;
        *)  if [[ -z "$SRC" ]]; then SRC="$1"; elif [[ -z "$TARGET" ]]; then TARGET="$1"
            else die "unexpected argument: $1"; fi; shift ;;
    esac
done
[[ -n "$SRC" && -n "$TARGET" ]] || { usage >&2; exit 2; }
[[ -f "$INBOX_FILE_SH" ]] || die "inbox-file.sh not found at $INBOX_FILE_SH — cannot file the handoff item"
# ⛔ Fail closed: this script's commits are invisible to the PreToolUse commit guard, so
#    without the guard to run here they would be the one commit path nothing scans.
if (( COMMIT )) && [[ ! -f "$COMMIT_GUARD" ]]; then
    die "secret-commit-guard.sh not found at $COMMIT_GUARD — refusing to commit unscanned. Use --no-commit and commit by hand (the hook scans that). Nothing was changed."
fi

# ── Resolve both ends ────────────────────────────────────────────────────────
[[ -f "$SRC" ]] || die "source is not a file: $SRC"
SRC="$(readlink -f "$SRC")"
SRC_ROOT="$(git -C "$(dirname "$SRC")" rev-parse --show-toplevel 2>/dev/null)" \
    || die "source is not inside a git repository: $SRC"
SRC_REL="${SRC#"$SRC_ROOT"/}"

# The target directory may not exist yet (docs/ often doesn't): anchor on its nearest
# existing ancestor to find the repository, then create it.
TARGET="${TARGET%/}"
_anchor="$TARGET"
while [[ ! -d "$_anchor" ]]; do
    _anchor="$(dirname "$_anchor")"
done
TGT_ROOT="$(git -C "$_anchor" rev-parse --show-toplevel 2>/dev/null)" \
    || die "target is not inside a git repository: $TARGET"
TGT_ROOT="$(readlink -f "$TGT_ROOT")"
if [[ "$_anchor" == "$TARGET" ]]; then
    DEST_DIR="$(readlink -f "$TARGET")"
else
    DEST_DIR="$(readlink -f "$_anchor")/${TARGET#"$_anchor"/}"
fi
[[ "$DEST_DIR" == "$TGT_ROOT" ]] && DEST_DIR="$TGT_ROOT/docs"
DEST="$DEST_DIR/$(basename "$SRC")"
DEST_REL="${DEST#"$TGT_ROOT"/}"

[[ "$SRC_ROOT" != "$TGT_ROOT" ]] || die "source and target are the same project ($SRC_ROOT) — just move the file"
[[ ! -e "$DEST" ]] || die "destination already exists, refusing to overwrite: $DEST"
if (( POINTER )); then
    case "$SRC" in
        *.md|*.markdown|*.txt) ;;
        *) die "--replace-with-pointer rewrites the source as a markdown stub; refusing for a non-document file ($(basename "$SRC"))" ;;
    esac
fi

# ⛔ Cross-project boundary (reference/cross-project-rules.md): writing into a project that
#    has a LIVE Claude Code session is forbidden, whoever writes. Checked with the canonical
#    liveness test before anything is touched — on the target, and on the source too when
#    --replace-with-pointer is going to rewrite and commit there.
# ⇒ The CALLER's own session is excluded the way session-lock.sh's callers do it: its CC
#   process is an ANCESTOR of this script (Claude Code parents every Bash-tool command), so
#   excluding only this script's descendants ($$) refused a target's own session pulling a
#   file into its repo. With no CC ancestor (a plain terminal), only this process tree is.
# ⚠ Liveness is read from /proc/<pid>/cwd: where /proc is absent (macOS, Git Bash) the check
#   cannot see any session and says so instead of silently passing.
# ⛔ "No live session found" is evidence only when the scan can see Claude Code processes at
#   all (CFG-673). Inside Claude Code's Bash sandbox a PID namespace hides the host's — the
#   caller's own CC and every rival alike — so the scan finds nobody because it can see
#   nobody; check_lock answers "cannot determine" (rc 4) there, and this check used to pass.
#   Called from a session (Claude Code puts CLAUDECODE / CLAUDE_CODE_SESSION_ID into every
#   tool subprocess's environment), a blind scan refuses. From a plain terminal (`afleet
#   transfer` with no session running, as afleet's own lock scan before any CC exists)
#   seeing no CC is the normal case: it warns and goes on.
_lock_lib="$REPO_ROOT/setup/scripts/session-lock.sh"
if [[ -f "$_lock_lib" ]]; then
    # shellcheck disable=SC1090
    source "$_lock_lib"
    _ccself="$(_cc_self_pid)"
    _self="${_ccself:-$$}"
    _where="$(basename "$TGT_ROOT")"
    if (( POINTER )); then _where+=" or $(basename "$SRC_ROOT")"; fi
    if [[ ! -d /proc/self ]]; then
        echo "cross-project-transfer: warning: no /proc here — cannot detect a live session in $_where; make sure none is running." >&2
    fi
    if _project_has_live_cc "$TGT_ROOT" "$_self"; then
        die "$(basename "$TGT_ROOT") has a live Claude Code session — writing into a running project is forbidden. Re-run once it has closed, or file an inbox item instead. Nothing was changed."
    fi
    if (( POINTER )) && _project_has_live_cc "$SRC_ROOT" "$_self"; then
        die "$(basename "$SRC_ROOT") has a live Claude Code session — --replace-with-pointer would rewrite and commit in a running project. Transfer without it, or re-run once that session has closed. Nothing was changed."
    fi
    if ! _cc_visible "$_ccself"; then
        if [[ -n "${CLAUDECODE:-}${CLAUDE_CODE_SESSION_ID:-}${CC_SESSION_ID:-}" ]]; then
            die "cannot see any Claude Code process from here, not even the session this runs in (a sandboxed PID namespace hides the host's processes, or this install's process is not recognised) — so a live session in $_where cannot be ruled out. Nothing was changed. Run the transfer from a terminal on the host (afleet transfer ...), or file an inbox item instead."
        fi
        echo "cross-project-transfer: warning: no Claude Code process is visible here, so the live-session check had nothing to compare against — make sure no session is running in $_where." >&2
    fi
else
    # No liveness library, no check: the same blindness, from a missing file.
    if [[ -n "${CLAUDECODE:-}${CLAUDE_CODE_SESSION_ID:-}${CC_SESSION_ID:-}" ]]; then
        die "session-lock.sh not found at $_lock_lib — the live-session check cannot run, so a live session in the target cannot be ruled out. Nothing was changed."
    fi
    echo "cross-project-transfer: warning: session-lock.sh not found — the live-session check did not run; make sure no session is running in $(basename "$TGT_ROOT")." >&2
fi

# Registry name for a repo root (Path column), falling back to the directory name.
registry_name() {
    local root="$1" name=""
    if [[ -f "$REGISTRY" ]]; then
        name=$(awk -F'|' -v root="$root" -v home="$HOME" '
            /^\| / {
                n = $2; p = $5
                gsub(/^[ \t]+|[ \t]+$/, "", n); gsub(/^[ \t]+|[ \t]+$/, "", p); gsub(/`/, "", p)
                sub(/^~/, home, p)
                if (p == root) { print n; exit }
            }' "$REGISTRY")
    fi
    printf '%s' "${name:-$(basename "$root")}"
}
tilde() { local p="$1"; [[ "$p" == "$HOME"/* ]] && p="~/${p#"$HOME"/}"; printf '%s' "$p"; }

SRC_PROJECT="$(registry_name "$SRC_ROOT")"
[[ -n "$PROJECT" ]] || PROJECT="$(registry_name "$TGT_ROOT")"

# ── Automatic description ────────────────────────────────────────────────────
TITLE="$(basename "$SRC")"
if grep -Iq . "$SRC" 2>/dev/null; then
    _h=$(grep -m1 '^#[[:space:]]' "$SRC" | sed 's/^#*[[:space:]]*//; s/[[:space:]]*$//' || true)
    [[ -n "$_h" ]] && TITLE="$_h"
    if [[ -z "$SUMMARY" ]]; then
        SUMMARY=$(awk 'NF && !/^#/ && !/^(---|```|<!--)/ { print; exit }' "$SRC" | cut -c1-240)
    fi
    LINES=$(wc -l < "$SRC" | tr -d ' ')
    SIZE="${LINES} lines"
else
    SIZE="$(wc -c < "$SRC" | tr -d ' ') bytes"
fi
SUMMARY="${SUMMARY//$'\n'/ }"
DATE="$(date +%Y-%m-%d)"
HOST="$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"

BODY="Transferred \`$SRC_REL\` from $SRC_PROJECT into this project as \`$DEST_REL\` — \"$TITLE\" ($SIZE)."
[[ -n "$SUMMARY" ]] && BODY="$BODY Summary: $SUMMARY"
if (( POINTER )); then
    BODY="$BODY The source is now a pointer stub; this copy is canonical."
fi
BODY="$BODY Integrate it: link it from wherever it drives work, or file it where it belongs."

if (( DRY )); then
    echo "DRY RUN — nothing will be changed"
    echo "  copy     $(tilde "$SRC") -> $(tilde "$DEST")"
    echo "  inbox    [$TYPE] $PRIORITY for $PROJECT: $BODY"
    (( POINTER )) && echo "  pointer  $(tilde "$SRC") becomes a stub -> $(tilde "$DEST")"
    (( COMMIT ))  && echo "  commit   $SRC_PROJECT: $SRC_REL (if changed); $PROJECT: $DEST_REL"
    exit 0
fi

# Undo steps 1-2 (and their staging) — used when a later step refuses. Idempotent.
SRC_BACKUP=""
rollback() {
    if (( COMMIT )); then
        if git -C "$TGT_ROOT" cat-file -e "HEAD:$DEST_REL" 2>/dev/null; then
            git -C "$TGT_ROOT" reset -q -- "$DEST_REL" 2>/dev/null || true
        else
            git -C "$TGT_ROOT" rm -q --cached --ignore-unmatch -- "$DEST_REL" >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$DEST"
    rmdir "$DEST_DIR" 2>/dev/null || true
    if [[ -n "$SRC_BACKUP" ]]; then
        if (( COMMIT )); then
            git -C "$SRC_ROOT" reset -q -- "$SRC_REL" 2>/dev/null || true
        fi
        cp -p "$SRC_BACKUP" "$SRC"
        rm -f "$SRC_BACKUP"
        SRC_BACKUP=""
    fi
}

# Stage <rel> in <repo> and scan that repo's staged diff with secret-commit-guard.sh —
# fed the payload the PreToolUse hook would see for a `git commit` typed there. Its
# BLOCKED report goes to stderr as is. rc 0 = clean; anything else (hit, guard error) = stop.
stage_and_scan() {
    local repo="$1" rel="$2" what="$3" rc=0
    if ! git -C "$repo" add -- "$rel"; then
        rollback
        die "cannot stage $what ($rel in $repo) — gitignored? Nothing was changed. Use --no-commit to copy it without committing."
    fi
    ( cd "$repo" && printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit"}}' \
        | bash "$COMMIT_GUARD" >/dev/null ) || rc=$?
    if (( rc != 0 )); then
        rollback
        die "the credential scan stopped the commit of $what (guard exit $rc) — rolled back: nothing is left copied, stubbed, filed or committed. Remove the value from the source and re-run."
    fi
}

# ── 1. copy ──────────────────────────────────────────────────────────────────
mkdir -p "$DEST_DIR"
cp -p "$SRC" "$DEST"
echo "copied   $(tilde "$SRC") -> $(tilde "$DEST")"

# ── 2. pointer stub (the original is kept until the commits land) ───────────
if (( POINTER )); then
    SRC_BACKUP="$(mktemp "${TMPDIR:-/tmp}/xfer-src.XXXXXX")"
    cp -p "$SRC" "$SRC_BACKUP"
    {
        printf '# %s — moved to %s\n\n' "$TITLE" "$PROJECT"
        printf '> **Moved.** The canonical copy of this file now lives in **%s**:\n' "$PROJECT"
        printf '> `%s` (transferred %s by `cross-project-transfer.sh`).\n' "$(tilde "$DEST")" "$DATE"
        printf '> Edit it there — this stub only keeps old links resolving.\n'
        [[ -n "$SUMMARY" ]] && printf '\n**Summary:** %s\n' "$SUMMARY"
    } > "$SRC"
    echo "pointer  $(tilde "$SRC") -> $(tilde "$DEST")"
fi

# ── 3. credential scan of exactly what will be committed ─────────────────────
if (( COMMIT )); then
    stage_and_scan "$TGT_ROOT" "$DEST_REL" "the copy"
    (( POINTER )) && stage_and_scan "$SRC_ROOT" "$SRC_REL" "the pointer stub"
fi

# ── 4. inbox (the registry check lives in inbox-file.sh; roll back on refusal) ─
if ! bash "$INBOX_FILE_SH" --project "$PROJECT" --type "$TYPE" --priority "$PRIORITY" \
        --summary "file transfer from $SRC_PROJECT" --source "$SRC_PROJECT $HOST $DATE" \
        --body "$BODY"; then
    rollback
    die "inbox item refused — copy rolled back, nothing else changed"
fi

# ── 5. commit exactly our paths — the target first ──────────────────────────
if (( COMMIT )); then
    if ! git -C "$TGT_ROOT" commit -q -m "Receive $DEST_REL from $SRC_PROJECT (cross-project transfer)" -- "$DEST_REL"; then
        if [[ -n "$SRC_BACKUP" ]]; then
            git -C "$SRC_ROOT" reset -q -- "$SRC_REL" 2>/dev/null || true
            cp -p "$SRC_BACKUP" "$SRC"; rm -f "$SRC_BACKUP"; SRC_BACKUP=""
        fi
        die "commit in $PROJECT failed — the copy is staged at $(tilde "$DEST") and the inbox item is filed; the source was left as it was. Commit the copy by hand."
    fi
    echo "commit   $PROJECT: $DEST_REL"
    if (( POINTER )); then
        git -C "$SRC_ROOT" commit -q -m "Transfer $SRC_REL to $PROJECT (pointer stub)" -- "$SRC_REL" \
            || die "commit in $SRC_PROJECT failed — the canonical copy is committed in $PROJECT; the pointer stub is written and staged at $(tilde "$SRC"). Commit it by hand."
        echo "commit   $SRC_PROJECT: $SRC_REL (pointer stub)"
    fi
fi
[[ -z "$SRC_BACKUP" ]] || rm -f "$SRC_BACKUP"
echo "done: $(basename "$SRC") handed to $PROJECT"
