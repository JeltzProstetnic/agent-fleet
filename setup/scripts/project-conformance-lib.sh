#!/usr/bin/env bash
# project-conformance-lib.sh — does a project carry what a new project receives at setup? (CFG-1094)
#
# Sourced by setup/scripts/project-conformance.sh (the CLI the hooks call). The spec is DERIVED
# from the files that define a new project, so a template addition extends the check with no
# code change here:
#   marker        line 1 of setup/projects/_templates/*/CLAUDE.md.template (agent-fleet-managed)
#   githooks      every file in setup/projects/_templates/.githooks/ (the commit-size guard, CFG-490)
#   gitignore     every line of setup/config/project-gitignore.conf
#   knowledge     setup/config/project-type-knowledge.conf rows for the project's registry type,
#                 MINUS every file the global CLAUDE.md's conditional-loading table already
#                 triggers (`knowledge/<file>.md` in a table row of the deployed
#                 ~/.claude/CLAUDE.md): a session loads those on trigger anyway, so a per-project
#                 row is redundant. Derived from the file — a new global row removes the finding.
#   manifest      a CLAUDE.md (under .claude/ first, then the root — as check 10 looks)
#   retired       setup/config/retired-names.conf: a pointer to a retired name in the manifest
#   tmp           tracked files under tmp/ (lib-tmp-lint.sh, the check-25 detector)
# Items are FIX (mechanical: fixed in place by pc_fix), FILE (a decision for the project's own
# session: one idempotent backlog item, check-10 precedent) or NOTE (reported only: git items do
# not apply — not a repository root, the mobile snapshot — or the project ships its OWN
# .githooks/pre-commit, e.g. a credential guard of its own, which is kept and never overwritten). The
# ONLY CLAUDE.md text pc_fix rewrites is a retired-name pointer (Q-1094-INBOX); the marker and
# knowledge rows are never written — the marker's absence is also check 12's /init signal, so a
# human confirms it. A filed item is P2 (Q-1094-ITEMPRIO; check 10's own item stays P1 — the
# priority is the caller's, lib-backlog-item.sh only places the line).
# Opt-out (Q-1094-SEARXNG): a `.fleet-conformance-skip` file in the project root (content ignored,
# may hold a one-line reason — an upstream clone, a repo that is not ours) makes pc_check yield one
# NOTE and pc_fix write nothing; nothing is filed there and the sweep never counts it as drift.
# Seams (tests): PC_TEMPLATES_DIR PC_RETIRED_CONF PC_GITIGNORE_CONF PC_TYPE_KNOWLEDGE PC_REGISTRY
# PC_GLOBAL_CLAUDE.

[[ -n "${_PC_LIB_LOADED:-}" ]] && return 0
_PC_LIB_LOADED=1

PC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PC_REPO_ROOT="$(cd "$PC_LIB_DIR/../.." && pwd)"
PC_TEMPLATES="${PC_TEMPLATES_DIR:-$PC_REPO_ROOT/setup/projects/_templates}"
PC_RETIRED_CONF="${PC_RETIRED_CONF:-$PC_REPO_ROOT/setup/config/retired-names.conf}"
PC_GITIGNORE_CONF="${PC_GITIGNORE_CONF:-$PC_REPO_ROOT/setup/config/project-gitignore.conf}"
PC_TYPE_KNOWLEDGE="${PC_TYPE_KNOWLEDGE:-$PC_REPO_ROOT/setup/config/project-type-knowledge.conf}"
PC_REGISTRY_DEFAULT="${PC_REGISTRY:-$PC_REPO_ROOT/registry.md}"
# The global CLAUDE.md a session actually reads: the deployed copy; the repo source when a
# machine has none deployed (tests sandbox HOME, so they set the seam or get the repo file).
PC_GLOBAL_CLAUDE="${PC_GLOBAL_CLAUDE:-}"
if [ -z "$PC_GLOBAL_CLAUDE" ]; then
    if [ -f "$HOME/.claude/CLAUDE.md" ]; then PC_GLOBAL_CLAUDE="$HOME/.claude/CLAUDE.md"
    else PC_GLOBAL_CLAUDE="$PC_REPO_ROOT/global/CLAUDE.md"; fi
fi
PC_OPT_OUT_MARKER=".fleet-conformance-skip"
PC_CHANGED_FILES=""     # newline-separated, repo-relative, set by pc_fix
PC_FIXED=""             # pc_fix's FIXED lines, also kept here so a caller need not capture stdout
_PC_CC_CACHE=""         # "pid|cwd" lines of live Claude Code processes, filled on first use

# shellcheck source=/dev/null
source "$PC_REPO_ROOT/global/hooks/lib-portable.sh" 2>/dev/null || true
type _python3 >/dev/null 2>&1 || _python3() { python3 "$@"; }
type _have_python3 >/dev/null 2>&1 || _have_python3() { command -v python3 >/dev/null 2>&1; }
# shellcheck source=/dev/null
source "$PC_REPO_ROOT/global/hooks/lib-tmp-lint.sh"
# shellcheck source=/dev/null
source "$PC_REPO_ROOT/global/hooks/lib-backlog-item.sh"
# shellcheck source=/dev/null
source "$PC_LIB_DIR/session-lock.sh"

# ── Registry ─────────────────────────────────────────────────────────────────

# pc_registry_rows [registry] → "name|path|type" per pathed row of the "## Projects" table (~ expanded).
# Other tables are ignored; a row without a backticked ~/ or / path is not a project on any machine.
pc_registry_rows() {
    local reg="${1:-$PC_REGISTRY_DEFAULT}"
    [ -f "$reg" ] || return 1
    awk -F'|' -v home="$HOME" '
        /^## / { in_projects = ($0 ~ /^## Projects/); next }
        !in_projects || !/^\| / { next }
        {
            name = $2; p = $5; t = $8
            gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (name == "Project" || name ~ /^-+$/) next
            if (match(p, /`[^`]+`/)) p = substr(p, RSTART + 1, RLENGTH - 2); else next
            gsub(/^[ \t]+|[ \t]+$/, "", p)
            sub(/^~/, home, p)
            if (p ~ /^\//) print name "|" p "|" t
        }' "$reg"
}

# pc_registry_lookup <dir> [registry] → the row whose path is <dir>; rc 1 when unregistered.
pc_registry_lookup() {
    local target row p
    target=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    while IFS= read -r row; do
        p="${row#*|}"; p="${p%%|*}"
        [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$target" ] || continue
        printf '%s\n' "$row"; return 0
    done < <(pc_registry_rows "${2:-}")
    return 1
}

# pc_manifest <dir> → the project manifest: the CLAUDE.md whose line 1 carries the agent-fleet-managed
# marker (some projects keep a rules file under .claude/CLAUDE.md next to the fleet manifest at the
# root); with no marked file the root one, else .claude/CLAUDE.md; rc 1 when there is none.
pc_manifest() {
    local f
    for f in "$1/CLAUDE.md" "$1/.claude/CLAUDE.md"; do
        [ -f "$f" ] && head -1 "$f" | grep -q 'agent-fleet-managed' && { printf '%s\n' "$f"; return 0; }
    done
    for f in "$1/CLAUDE.md" "$1/.claude/CLAUDE.md"; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# ── Upstream and repo state (read-only; the last FETCHED state, no network) ──────────────────

# pc_behind_count <dir> → commits HEAD is behind @{u} (0 without an upstream)
pc_behind_count() { git -C "$1" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0; }

# pc_upstream_has <dir> <path> — rc 0 when @{u} already carries <path>
pc_upstream_has() { git -C "$1" cat-file -e "@{u}:$2" 2>/dev/null; }

# pc_upstream_show <dir> <path> → the file as @{u} has it (empty when absent)
pc_upstream_show() { git -C "$1" show "@{u}:$2" 2>/dev/null; }

# pc_fix_targets <dir> → the repo-relative paths a fix or a filing may write
pc_fix_targets() {
    local f m
    for f in "$PC_TEMPLATES"/.githooks/*; do [ -f "$f" ] && printf '.githooks/%s\n' "$(basename "$f")"; done
    printf '.gitignore\nbacklog.md\n'
    m=$(pc_manifest "$1") && printf '%s\n' "${m#"$1"/}"
}

# pc_repo_state <dir> → "" when a fix may be committed here, else why not: a merge, rebase or
# cherry-pick in progress, a detached HEAD, a branch behind its fetched upstream (the pull would
# collide with what the fix adds), or target files already dirty (a commit would carry hunks
# that are not the fix's).
pc_repo_state() {
    local d="$1" gd n dirty
    gd=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null) || { printf 'not a git repository'; return 0; }
    git -C "$d" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && { printf 'merge in progress'; return 0; }
    [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] && { printf 'rebase in progress'; return 0; }
    git -C "$d" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1 && { printf 'cherry-pick in progress'; return 0; }
    git -C "$d" symbolic-ref -q HEAD >/dev/null 2>&1 || { printf 'detached HEAD'; return 0; }
    n=$(pc_behind_count "$d"); [ "$n" -gt 0 ] && { printf 'behind upstream by %s commit(s) — pull first' "$n"; return 0; }
    dirty=$(pc_fix_targets "$d" | xargs -r git -C "$d" status --porcelain -- 2>/dev/null | awk '{print $NF}' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    [ -n "$dirty" ] && printf 'dirty: %s' "$dirty"
    return 0
}

# ── Spec pieces ──────────────────────────────────────────────────────────────

pc_retired_blocks() { sed -nE 's/^\[(.+)\][[:space:]]*$/\1/p' "$PC_RETIRED_CONF" 2>/dev/null; }

# pc_retired_field <block> <key> → the value (first match)
pc_retired_field() {
    awk -v blk="[$1]" -v key="$2" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^\[/ { cur = $0; sub(/[[:space:]]+$/, "", cur); next }
        cur == blk {
            eq = index($0, "="); if (!eq) next
            k = substr($0, 1, eq - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (k != key) next
            v = substr($0, eq + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            print v; exit
        }' "$PC_RETIRED_CONF" 2>/dev/null
}

pc_gitignore_lines() { grep -vE '^[[:space:]]*(#|$)' "$PC_GITIGNORE_CONF" 2>/dev/null | sed 's/[[:space:]]*$//'; }

# pc_gitignore_has <gitignore> <pattern> — rc 0 when some line ignores the same thing: the pattern
# itself, with a leading slash, and for a directory pattern "x/" also "x" and "x/*". CR-stripped
# (a CRLF .gitignore never matched grep -x, CFG-1116).
pc_gitignore_has() {
    local gi="$1" pat="$2" pats=("$2" "/$2")
    [ -f "$gi" ] || return 1
    case "$pat" in */) pats+=("${pat%/}" "/${pat%/}" "${pat}*" "/${pat}*") ;; esac
    tr -d '\r' < "$gi" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -qxF -f <(printf '%s\n' "${pats[@]}")
}

# pc_type_files <type> → knowledge files the registry type demands ("a + b" takes the union)
pc_type_files() {
    local types; types=$(printf '%s' "$1" | tr '+' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr 'A-Z' 'a-z' | grep -v '^$')
    [ -n "$types" ] && [ -f "$PC_TYPE_KNOWLEDGE" ] || return 0
    awk -F'|' -v want="$(printf '%s' "$types" | tr '\n' ' ') " '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        { t = tolower($1); f = $3; gsub(/^[ \t]+|[ \t]+$/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", f)
          if (index(want, t " ") && !(f in seen)) { seen[f] = 1; print f } }' "$PC_TYPE_KNOWLEDGE"
}

# pc_globally_triggered <file.md> — rc 0 when a table row of the global CLAUDE.md names knowledge/<file>
pc_globally_triggered() {
    [ -f "$PC_GLOBAL_CLAUDE" ] || return 1
    grep -F "knowledge/$1" "$PC_GLOBAL_CLAUDE" 2>/dev/null | grep -q '^[[:space:]]*|'
}

# pc_type_files_due <type> → the type's files minus the globally triggered ones
pc_type_files_due() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        pc_globally_triggered "$f" || printf '%s\n' "$f"
    done < <(pc_type_files "$1")
}

# pc_retired_lines <manifest> <literal> <keep-words> → line numbers pointing at the retired name
pc_retired_lines() {
    awk -v lit="$2" -v keep="$3" '
        { if (index($0, lit) == 0) next; low = tolower($0); n = split(keep, K, " ")
          for (i = 1; i <= n; i++) if (K[i] != "" && index(low, tolower(K[i]))) next
          print NR }' "$1" 2>/dev/null
}

# pc_opted_out <dir> — rc 0 when the project root carries the opt-out marker
pc_opted_out() { [ -f "$1/$PC_OPT_OUT_MARKER" ]; }

# pc_repo_note <dir> → "" when git items apply, else the NOTE text
pc_repo_note() {
    local d top
    d=$(cd "$1" 2>/dev/null && pwd -P) || { printf 'directory unreadable'; return 0; }
    [ -f "$d/.mobile-repo" ] && { printf 'mobile snapshot (.mobile-repo) — git items skipped'; return 0; }
    top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || { printf 'not a git repository — git items skipped'; return 0; }
    [ "$top" = "$d" ] || printf 'not a repository root (inside %s) — git items skipped' "$top"
}

# ── pc_check <dir> <name> <type> — FIX|kind|text, FILE|kind|text, NOTE|kind|text; writes nothing ──
# Where git items do not apply (nested dir, mobile snapshot, no git) nothing can be fixed or filed
# by any session, so every finding there is a NOTE; a missing manifest is a NOTE for the same reason.
pc_check() {
    local dir="$1" type="${3:-}" note m="" rel="" items=""
    pc_opted_out "$dir" && { printf 'NOTE|opted-out|%s present — nothing checked, fixed or filed\n' "$PC_OPT_OUT_MARKER"; return 0; }
    note=$(pc_repo_note "$dir")
    [ -n "$note" ] && items="NOTE|repo|$note"$'\n'
    if m=$(pc_manifest "$dir"); then rel="${m#"$dir"/}"; else items="${items}NOTE|manifest|no CLAUDE.md (looked in ./ and .claude/)"$'\n'; fi
    [ -z "$note" ] && items="${items}$(_pc_check_git "$dir")"$'\n'
    [ -n "$m" ] && items="${items}$(_pc_check_manifest "$m" "$rel" "$type")"$'\n'
    items=$(printf '%s\n' "$items" | grep -v '^$')
    if [ -n "$note" ]; then printf '%s\n' "$items" | sed 's/^FIX|/NOTE|/; s/^FILE|/NOTE|/'; else printf '%s\n' "$items"; fi
    return 0
}

_pc_check_git() {   # <dir> — githooks, gitignore, tracked tmp/
    local dir="$1" f b differs="" missing="" n
    for f in "$PC_TEMPLATES"/.githooks/*; do
        [ -f "$f" ] || continue; b=$(basename "$f")
        if [ ! -f "$dir/.githooks/$b" ]; then printf 'FIX|githooks|.githooks/%s missing (copy from template)\n' "$b"
        elif ! cmp -s "$f" "$dir/.githooks/$b"; then differs="$differs .githooks/$b"
        elif [ ! -x "$dir/.githooks/$b" ]; then printf 'FIX|githooks|.githooks/%s not executable\n' "$b"; fi
    done
    while IFS= read -r f; do pc_gitignore_has "$dir/.gitignore" "$f" || missing="${missing:+$missing, }$f"; done < <(pc_gitignore_lines)
    [ -n "$missing" ] && printf 'FIX|gitignore|.gitignore lacks: %s\n' "$missing"
    for f in $differs; do printf "NOTE|githooks|%s differs from the template (the project's own hook — kept, never overwritten)\n" "$f"; done
    n=$(tmp_lint_tracked_count "$dir")
    [ "${n:-0}" -gt 0 ] && printf 'FILE|tmp|%s tracked file(s) under tmp/ (git rm -r --cached tmp/ in this project'"'"'s session)\n' "$n"
    return 0
}

_pc_check_manifest() {   # <manifest> <rel> <type> — retired pointers, marker, knowledge rows
    local m="$1" rel="$2" type="$3" lit n f missing=""
    while IFS= read -r lit; do
        [ -n "$lit" ] && [ -n "$(pc_retired_field "$lit" replacement)" ] || continue
        n=$(pc_retired_lines "$m" "$lit" "$(pc_retired_field "$lit" keep-when)" | wc -l | tr -d ' ')
        [ "$n" -gt 0 ] && printf 'FIX|retired|%s: %s line(s) point at retired %s\n' "$rel" "$n" "$lit"
    done < <(pc_retired_blocks)
    head -1 "$m" | grep -q 'agent-fleet-managed' || printf 'FILE|marker|%s line 1 lacks the agent-fleet-managed marker (the template comment; confirm the manifest is the fleet'"'"'s, not /init'"'"'s — check 12)\n' "$rel"
    while IFS= read -r f; do [ -n "$f" ] && ! grep -qF "knowledge/$f" "$m" && missing="${missing:+$missing, }$f"; done < <(pc_type_files_due "$type")
    [ -n "$missing" ] && printf 'FILE|knowledge|Knowledge Loading lacks the %s rows: %s\n' "$type" "$missing"
    return 0
}

# ── pc_fix <dir> <name> <type> — apply the FIX items; FIXED|kind|text per fix; PC_CHANGED_FILES ──
pc_fix() {
    local dir="$1" m
    PC_CHANGED_FILES=""; PC_FIXED=""
    pc_opted_out "$dir" && return 0                   # opted out: nothing is written
    [ -z "$(pc_repo_note "$dir")" ] || return 0      # nested, mobile, non-git: nothing is written
    _pc_fix_githooks "$dir"
    _pc_fix_gitignore "$dir"
    if m=$(pc_manifest "$dir"); then _pc_fix_retired "$dir" "$m"; fi
    return 0
}

_pc_changed() { PC_CHANGED_FILES="${PC_CHANGED_FILES:+$PC_CHANGED_FILES$'\n'}$1"; }
_pc_fixed()   { PC_FIXED="${PC_FIXED:+$PC_FIXED$'\n'}$1"; printf '%s\n' "$1"; }

# Every fix skips what the fetched upstream already carries (MAJOR 1): a pull right after the
# hook would otherwise refuse to overwrite the untracked file the hook just created.
_pc_fix_githooks() {
    local dir="$1" f b changed=0
    for f in "$PC_TEMPLATES"/.githooks/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        if [ ! -f "$dir/.githooks/$b" ]; then
            pc_upstream_has "$dir" ".githooks/$b" && continue
            mkdir -p "$dir/.githooks" && cp "$f" "$dir/.githooks/$b" && chmod +x "$dir/.githooks/$b" || continue
            _pc_fixed "FIXED|githooks|.githooks/$b copied from the template"; _pc_changed ".githooks/$b"; changed=1
        elif cmp -s "$f" "$dir/.githooks/$b" && [ ! -x "$dir/.githooks/$b" ]; then
            chmod +x "$dir/.githooks/$b" || continue
            _pc_fixed "FIXED|githooks|.githooks/$b made executable"; _pc_changed ".githooks/$b"; changed=1
        fi
    done
    # Arm it: with the fleet dispatcher (CFG-892) nothing to set; without, a local core.hooksPath.
    [ "$changed" -eq 1 ] && [ -f "$PC_LIB_DIR/ensure-githooks.sh" ] && bash "$PC_LIB_DIR/ensure-githooks.sh" "$dir" >/dev/null 2>&1
    return 0
}

_pc_fix_gitignore() {
    local gi="$1/.gitignore" missing=() l eol=$'\n' list="" up
    up=$(mktemp "${TMPDIR:-/tmp}/pc-upstream-gi.XXXXXX") || return 0
    pc_upstream_show "$1" .gitignore > "$up"
    while IFS= read -r l; do
        pc_gitignore_has "$gi" "$l" && continue
        pc_gitignore_has "$up" "$l" && continue      # the pull will bring it
        missing+=("$l")
    done < <(pc_gitignore_lines)
    rm -f "$up"
    [ ${#missing[@]} -gt 0 ] || return 0
    if [ -s "$gi" ]; then
        grep -q $'\r' "$gi" 2>/dev/null && eol=$'\r\n'
        [ -n "$(tail -c1 "$gi")" ] && { printf '%s' "$eol" >> "$gi" || return 0; }
    fi
    for l in "${missing[@]}"; do printf '%s%s' "$l" "$eol" >> "$gi" || return 0; list="${list:+$list, }$l"; done
    _pc_fixed "FIXED|gitignore|.gitignore +${#missing[@]} line(s): $list"; _pc_changed ".gitignore"
}

_pc_fix_retired() {
    local dir="$1" m="$2" rel="${2#"$1"/}" lit rep suf keep n tmp up touched=0
    while IFS= read -r lit; do
        [ -n "$lit" ] || continue
        rep=$(pc_retired_field "$lit" replacement); [ -n "$rep" ] || continue
        suf=$(pc_retired_field "$lit" suffix); keep=$(pc_retired_field "$lit" keep-when)
        n=$(pc_retired_lines "$m" "$lit" "$keep" | wc -l | tr -d ' ')
        [ "$n" -gt 0 ] || continue
        if pc_upstream_has "$dir" "$rel"; then     # already rewritten upstream: the pull brings it
            up=$(mktemp "${TMPDIR:-/tmp}/pc-upstream-m.XXXXXX") || return 0
            pc_upstream_show "$dir" "$rel" > "$up"
            n=$(pc_retired_lines "$up" "$lit" "$keep" | wc -l | tr -d ' '); rm -f "$up"
            [ "$n" -gt 0 ] || continue
            n=$(pc_retired_lines "$m" "$lit" "$keep" | wc -l | tr -d ' ')
        fi
        tmp=$(mktemp "${TMPDIR:-/tmp}/pc-manifest.XXXXXX") || return 0
        if _pc_rewrite "$m" "$lit" "$rep" "$suf" "$keep" > "$tmp" && _pc_write_atomic "$m" "$tmp"; then
            _pc_fixed "FIXED|retired|$rel: $n line(s) rewritten from $lit to $rep"; touched=1
        fi
        rm -f "$tmp"
    done < <(pc_retired_blocks)
    [ "$touched" -eq 1 ] && _pc_changed "$rel"
    return 0
}

# _pc_write_atomic <target> <content-file> — a temp file beside the target, the target's mode, the
# target's final-newline state (the rewrite emits one per line; a file that had none keeps none),
# then mv over it. Line endings are the rewrite's business (CR stays inside the line).
_pc_write_atomic() {
    local target="$1" content="$2" tmp size
    tmp=$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX") || return 1
    if [ -s "$target" ] && [ -n "$(tail -c1 "$target")" ]; then
        size=$(wc -c < "$content" | tr -d ' ')
        head -c "$((size - 1))" "$content" > "$tmp"
    else
        cat "$content" > "$tmp"
    fi || { rm -f "$tmp"; return 1; }
    chmod --reference="$target" "$tmp" 2>/dev/null || chmod "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" "$tmp" 2>/dev/null
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

# _pc_rewrite <file> <literal> <replacement> <suffix> <keep-words> — the rewritten file on stdout.
# Fixed-string, line by line (CRLF survives): every occurrence of the literal becomes the
# replacement; the suffix goes once per line right after the first one (after its closing
# backtick when the literal sits in backticks), {prefix} = the path prefix that stood before it.
_pc_rewrite() {
    awk -v lit="$2" -v rep="$3" -v suf="$4" -v keep="$5" '
        function repl(s, a, b,   i) { i = index(s, a); return i ? substr(s, 1, i - 1) b substr(s, i + length(a)) : s }
        {
            if (index($0, lit) == 0) { print; next }
            low = tolower($0); nk = split(keep, K, " ")
            for (i = 1; i <= nk; i++) if (K[i] != "" && index(low, tolower(K[i]))) { print; next }
            out = ""; rest = $0; first = 1
            while ((p = index(rest, lit)) > 0) {
                before = substr(rest, 1, p - 1); after = substr(rest, p + length(lit))
                out = out before rep
                if (first) {
                    pre = before; sub(/.*[ \t`|(]/, "", pre)
                    s = repl(suf, "{prefix}", pre)
                    if (substr(after, 1, 1) == "`") { out = out "`" s; after = substr(after, 2) } else { out = out s }
                    first = 0
                }
                rest = after
            }
            print out rest
        }' "$1"
}

# ── pc_file_backlog <dir> <name> <issues> — one open "Project conformance" item (check-10 precedent) ──
pc_file_backlog() {
    local bl="$1/backlog.md" id item
    if [ -f "$bl" ] && grep -qE '^- \[[ >?]\] .*\*\*Project conformance\*\*' "$bl" 2>/dev/null; then printf 'TRACKED\n'; return 0; fi
    pc_opted_out "$1" && { printf 'TRACKED\n'; return 0; }     # opted out: never filed
    item="- [ ] [P2] {ID}**Project conformance**: $3. The mechanical items were fixed by the SessionStart check; these need this project's own session (knowledge rows → the CLAUDE.md Knowledge Loading table; tracked tmp/ files → \`git rm -r --cached tmp/\`; marker → line 1 of CLAUDE.md once the manifest is confirmed as the fleet's). Filed by \`project-conformance.sh\` (CFG-1094)."
    id=$(backlog_add_item "$bl" "$2" "$item") || return 1
    printf 'FILED|%s\n' "${id:-backlog.md}"
}

# ── pc_trailers <dir> — the Rule-removed trailers rule-removal-guard.sh (CFG-897) will demand ──
# Runs the guard's own detector over HEAD's manifest vs the working tree and explains only the
# units a retired-name rewrite removed (approver and date from the conf); other removals are
# somebody's decision, never ours to write a trailer for.
pc_trailers() {
    local dir="$1" m rel old blocks lit lib="" d oldf newf blkf pyf py
    m=$(pc_manifest "$dir") || return 0
    rel=$(git -C "$dir" ls-files --full-name -- "$m" 2>/dev/null | head -1); [ -n "$rel" ] || return 0
    old=$(git -C "$dir" show "HEAD:$rel" 2>/dev/null) || return 0
    _have_python3 || { echo "project-conformance: python3 missing — Rule-removed trailers cannot be computed" >&2; return 0; }
    for d in "$PC_REPO_ROOT/global/hooks" "${HOME:-}/.claude/hooks"; do [ -f "$d/lib-rule-removal.sh" ] && { lib="$d/lib-rule-removal.sh"; break; }; done
    [ -n "$lib" ] || return 0
    # shellcheck source=/dev/null
    source "$lib"
    py=$(printf '%s\n' "$_RULE_REMOVAL_PY" | grep -vx 'sys.exit(main(sys.argv\[1:\]))')
    oldf=$(mktemp) && newf=$(mktemp) && blkf=$(mktemp) && pyf=$(mktemp) || return 0
    printf '%s\n' "$old" > "$oldf"; cat "$m" > "$newf"
    while IFS= read -r lit; do
        [ -n "$lit" ] && [ -n "$(pc_retired_field "$lit" replacement)" ] || continue
        printf '%s\t%s\t%s\n' "$lit" "$(pc_retired_field "$lit" approver)" "$(pc_retired_field "$lit" since)" >> "$blkf"
    done < <(pc_retired_blocks)
    printf '%s\n%s\n' "$py" '
old = open(sys.argv[1], encoding="utf-8", errors="replace").read()
new = open(sys.argv[2], encoding="utf-8", errors="replace").read()
blocks = [l.rstrip("\n").split("\t") for l in open(sys.argv[3], encoding="utf-8") if l.strip()]
for u in removed(old, new):
    for lit, who, since in blocks:
        if lit not in u: continue
        pre = re.sub(r"[*`]", "", u)[:PREFIX + 30]; cut = pre.rfind(" ", PREFIX)
        pre = pre[:cut] if cut > 0 else pre
        print("Rule-removed: \"%s\" retired-by %s %s" % (pre, who, since)); break' > "$pyf"
    _python3 "$pyf" "$oldf" "$newf" "$blkf" 2>/dev/null
    rm -f "$oldf" "$newf" "$blkf" "$pyf"
}

# ── pc_live_session <dir> → free | held: <why> | unknown: <why> — read-only, never removes a lock ──
# A lock is held when its machine is not this one (cannot verify) or its pid is alive; without
# that, a live Claude Code process cwd'd in the project (any session shape) holds it.
pc_live_session() {
    local lock="$1/.claude/.session-lock" host target line
    host="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
    if [ -f "$lock" ] && _read_lock "$lock" 2>/dev/null; then
        [ "$_LOCK_MACHINE" = "$host" ] || { printf 'held: lock by %s (cannot verify a remote pid)\n' "$_LOCK_MACHINE"; return 0; }
        [ -n "$_LOCK_PID" ] && _is_pid_alive "$_LOCK_PID" && { printf 'held: lock pid %s alive\n' "$_LOCK_PID"; return 0; }
    fi
    target=$(cd "$1" 2>/dev/null && pwd -P) || { printf 'unknown: directory unreadable\n'; return 0; }
    if [ -z "$_PC_CC_CACHE" ]; then
        _PC_CC_CACHE=$(pc_cc_sessions) || { printf 'unknown: process enumeration unavailable\n'; return 0; }
        [ -n "$_PC_CC_CACHE" ] || _PC_CC_CACHE="none"
    fi
    while IFS= read -r line; do
        [ "${line#*|}" = "$target" ] && { printf 'held: live Claude Code pid %s here\n' "${line%%|*}"; return 0; }
    done <<< "$_PC_CC_CACHE"
    printf 'free\n'
}

# pc_cc_sessions → "pid|cwd" for every live Claude Code process (one /proc walk per sweep)
pc_cc_sessions() {
    local pids p cwd
    pids=$(_enumerate_pids) || return 1
    for p in $pids; do
        _pid_is_cc "$p" || continue
        cwd=$(_pid_cwd "$p") || continue
        [ -n "$cwd" ] && printf '%s|%s\n' "$p" "$cwd"
    done
    return 0
}
