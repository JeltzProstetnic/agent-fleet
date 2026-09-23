#!/usr/bin/env bash
# cfg-boundary-guard.sh — PreToolUse hook: the cross-project write boundary.
#
# ONE policy, three tools. ~/.claude/* and <config-repo>/global/* are owned by the
# config repo. A session whose project is not the config repo may not write there,
# except the runtime allowlist below. Write and Edit are judged by file_path. Bash is
# judged by a HEURISTIC (CFG-674): the command text is parsed for write-ish constructs
# (lib-shell-scan.sh + lib-shell-write-cmds.sh), each target is resolved, and a target
# inside the owned area blocks. Before CFG-674 the hook returned on anything but
# Write/Edit, so `sed -i`, a heredoc, `tee`, `cp` or `git apply` wrote unguarded what
# the identical Edit call was refused.
#
# Detecting every write in arbitrary shell is undecidable. This raises the cost of an
# ACCIDENTAL breach; it does not close the class. Under-blocking is the designed
# failure mode: the Bash arm fires on every Bash call fleet-wide and a false block is a
# work stoppage, so anything the hook cannot resolve without running the command is
# skipped, never guessed at.
#
# SEEN: >, >>, N>, &>, >| ; tee ; sed -i/--in-place ; cp/install/ln/rsync destination
# and -t DIR ; every mv operand ; mkdir, touch, truncate ; dd of= ; git apply / patch
# via their +++ lines (file or heredoc) ; git checkout/restore/rm/mv pathspecs ;
# python open(path,'w'|'a'|'x') and Path(path).write_text/bytes literals ; bash -c '…'
# one level deep. ~ $HOME ${HOME} are expanded, ../ normalised, `cd` tracked across
# && ; | newline with subshell scope. Heredoc bodies and quoted strings are data.
# NOT SEEN: paths in other variables ($D/foo), command substitution, what a script or
# binary does internally (bash foo.sh, gpi, afd), xargs / find -exec, eval, rm, chmod,
# interpreters beyond the python literal forms, and any relative target after a cd the
# hook could not resolve.
#
# Exit 2 + stderr = block. Exit 0 = allow.

INPUT=$(cat)

# Classify on the payload BEFORE "tool_input" first, so a Bash command whose TEXT
# contains '"tool_name":"Write"' is still handled as Bash; fall back to the whole
# payload so an unexpected key order can never switch the guard off.
_classify() {
    case "$1" in
        *'"tool_name":"Write"'*|*'"tool_name": "Write"'*) TOOL=Write ;;
        *'"tool_name":"Edit"'*|*'"tool_name": "Edit"'*)   TOOL=Edit ;;
        *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*)   TOOL=Bash ;;
    esac
}
TOOL=""
_classify "${INPUT%%\"tool_input\"*}"
[[ -n "$TOOL" ]] || _classify "$INPUT"
[[ -n "$TOOL" ]] || exit 0

# Bash fast path, before any subprocess or repo detection: the owned area cannot be
# named without ".claude" or "global" in the text, and a target the hook could not
# resolve is skipped anyway. The two exceptions are git apply / patch, whose targets
# live inside the patch. Checked on the tool_input part of the payload only —
# transcript_path lives under ~/.claude on vanilla installs and would defeat it.
if [[ "$TOOL" == Bash ]]; then
    _TI="${INPUT#*\"tool_input\"}"
    if [[ "$_TI" != *".claude"* && "$_TI" != *global* && "$_TI" != *apply* && "$_TI" != *patch* ]]; then
        exit 0
    fi
fi

# ── Who is asking, what is owned ─────────────────────────────────────────────

# Detect config repo dynamically (supports both agent-fleet and cfg-agent-fleet)
source "$(dirname "${BASH_SOURCE[0]}")/lib-detect-repo.sh" 2>/dev/null || true
CONFIG_REPO="${CONFIG_REPO:-$(_detect_config_repo 2>/dev/null || echo "$HOME/agent-fleet")}"
CONFIG_REPO_NAME="$(basename "$CONFIG_REPO")"

CLAUDE_DIR="$HOME/.claude/"
CFG_GLOBAL="$CONFIG_REPO/global/"

# The config repo's own sessions may write anywhere in the owned area.
# For CONFIG_REPO/* paths: CONFIG_REPO is the authoritative project identity.
# For ~/.claude/* paths: PROJECT_DIR/PWD (symlinks resolve to cfg, defeating git-based detection).
_PROJECT="${PROJECT_DIR:-$PWD}"
if [[ "$_PROJECT" == "$CONFIG_REPO" || "$_PROJECT" == "$CONFIG_REPO/"* ]]; then
    exit 0
fi

# Allowlist: runtime state files that any project may write
CROSS_PROJECT_ALLOWLIST=(
    "$CLAUDE_DIR.active-persona"
)

# _owned PATH → 0 when PATH (absolute, ~ already expanded) is cfg-owned and not
# allowlisted. The owned dirs themselves count (cp INTO ~/.claude is a write there).
_owned() {
    local p="$1" a
    [[ "$p" == "$CLAUDE_DIR"* || "$p" == "${CLAUDE_DIR%/}" \
    || "$p" == "$CFG_GLOBAL"* || "$p" == "${CFG_GLOBAL%/}" ]] || return 1
    for a in "${CROSS_PROJECT_ALLOWLIST[@]}"; do
        [[ "$p" == "$a" ]] && return 1
    done
    return 0
}

# _block PATH [HOW] — HOW names the Bash construct; empty for Write/Edit.
_block() {
    if [[ -n "${2:-}" ]]; then
        echo "BLOCKED: $1 is owned by ${CONFIG_REPO_NAME} — this Bash command would write it via $2. Create a cross-project inbox item instead of editing directly. Rule: ~/.claude/* and ~/${CONFIG_REPO_NAME}/global/* are cfg-exclusive; Write and Edit are refused there too, so a shell write is not a bypass." >&2
    else
        echo "BLOCKED: $1 is owned by ${CONFIG_REPO_NAME}. Create a cross-project inbox item instead of editing directly. Rule: ~/.claude/* and ~/${CONFIG_REPO_NAME}/global/* are cfg-exclusive." >&2
    fi
    exit 2
}

# ── Write / Edit arm (unchanged policy) ──────────────────────────────────────

if [[ "$TOOL" != Bash ]]; then
    FILE_PATH=""
    if command -v jq &>/dev/null; then
        FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    else
        FILE_PATH=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    fi
    [ -z "$FILE_PATH" ] && exit 0
    RESOLVED_PATH="${FILE_PATH/#\~/$HOME}"
    _owned "$RESOLVED_PATH" && _block "$FILE_PATH"
    exit 0
fi

# ── Bash arm (CFG-674) ───────────────────────────────────────────────────────

CMD=""
if command -v jq &>/dev/null; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
    CMD=$(printf '%s' "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
          | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$CMD" ] && exit 0

source "$(dirname "${BASH_SOURCE[0]}")/lib-shell-scan.sh"
if ! type _scan_text &>/dev/null; then
    echo "cfg-boundary-guard: lib-shell-scan.sh not deployed — Bash arm inactive, Write/Edit arm unaffected"
    exit 0
fi

# The scanner's callback: one call per resolved write target.
_on_write_target() { _owned "$1" && _block "$1" "$2"; return 0; }

_CWD="$_PROJECT"
_scan_text "$CMD"
_scan_interpreter_literals "$CMD"
exit 0
