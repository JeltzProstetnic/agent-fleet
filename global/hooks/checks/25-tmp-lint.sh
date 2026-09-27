#!/usr/bin/env bash
# Check group 25: tmp/ lint (CFG-490)
# `tmp/` is the fleet's throwaway directory. A project where it is not gitignored, or
# already has tracked files under it, is one `git add -A` away from committing the
# throwaway pile — a project session on 2026-06-25 staged 46,964 tmp files that way, caught before
# push by luck. Every session checks its own project; a cfg-agent-fleet session also
# sweeps every project in registry.md that is checked out on this machine.
# Flag only: the fixes (.gitignore edit, `git rm -r --cached tmp/`) change the project's
# repo and are for its own session to make.
# Shared vars used: CONFIG_REPO, PROJECT_DIR, WARNINGS

_tl_issue() {  # <dir> → "tmp/ is not gitignored" / "N tracked file(s) under tmp/" / ""
    local d="$1" n
    # Only a repo's own root: a project nested in another repo is that repo's business.
    [ "$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" = "$d" ] || return 0
    # A tracked placeholder (tmp/.gitkeep, a self-ignoring tmp/.gitignore) is deliberate.
    n=$(git -C "$d" ls-files -- tmp 2>/dev/null | grep -cvxE 'tmp/\.(gitkeep|keep|gitignore)')
    if [ "${n:-0}" -gt 0 ]; then
        printf '%s tracked file(s) under tmp/' "$n"
    elif ! git -C "$d" check-ignore -q tmp/.tmp-lint-probe 2>/dev/null; then
        printf 'tmp/ is not gitignored'
    fi
}

_tl_found=""
_tl_seen=""
_tl_check() {  # <name> <dir>
    local what
    case " $_tl_seen " in *" $2 "*) return 0 ;; esac
    _tl_seen="$_tl_seen $2"
    [ -d "$2" ] || return 0
    what=$(_tl_issue "$2")
    [ -n "$what" ] && _tl_found="${_tl_found:+$_tl_found; }$1: $what"
}

_tl_check "$(basename "$PROJECT_DIR")" "$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)"

if [ -n "${CONFIG_REPO:-}" ] && [ -f "$CONFIG_REPO/registry.md" ] \
   && [ "$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" = "$(cd "$CONFIG_REPO" 2>/dev/null && pwd -P)" ]; then
    while IFS='|' read -r _tl_name _tl_path; do
        [ -n "$_tl_path" ] || continue
        case "$_tl_path" in "~/"*) _tl_path="$HOME/${_tl_path#\~/}" ;; esac
        _tl_check "$_tl_name" "$(cd "$_tl_path" 2>/dev/null && pwd -P)"
    done <<EOF
$(awk -F'|' 'NF > 5 && $5 ~ /`(~\/|\/)[^`]*`/ {
    n = $2; gsub(/^[ \t]+|[ \t]+$/, "", n)
    p = $5; sub(/^[^`]*`/, "", p); sub(/`.*$/, "", p)
    print n "|" p }' "$CONFIG_REPO/registry.md" 2>/dev/null)
EOF
fi

if [ -n "$_tl_found" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }TMP_LINT (CFG-490): $_tl_found. A \`git add -A\` there commits throwaway files — gitignore \`tmp/\` and \`git rm -r --cached tmp/\` in that project's own session."
fi
