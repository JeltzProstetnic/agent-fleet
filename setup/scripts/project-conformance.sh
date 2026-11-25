#!/usr/bin/env bash
# project-conformance.sh — are the fleet's projects carrying what a new project receives? (CFG-1094)
#
# The check itself lives in project-conformance-lib.sh (spec derived from the templates and
# conf files: marker, .githooks, gitignore lines, type knowledge rows, retired names, tmp/).
# This CLI is what the SessionStart checks and the one-time backfill call:
#
#   --project <dir> [--name N --type T] [--fix] [--file-backlog] [--brief]
#       One project (the registry supplies name and type; --name/--type stand in for a row;
#       an unregistered directory is not a fleet project and gets nothing). --fix applies the
#       mechanical items in place, --file-backlog files ONE backlog item for the rest (check-10
#       precedent), --brief prints the single PROJECT_CONFORMANCE line the per-project
#       SessionStart check adds (checks/30-project-conformance.sh): what was fixed, that the
#       session must commit it, which item was filed. Never commits (Q-1094-COMMIT).
#   --sweep [--fix [--commit-push [--co-author "<trailer>"]]] [--skip <name,name…>]
#       Every registered project on this machine, nested and dormant ones included; one line
#       each, absent projects reported, never skipped. Read-only without --fix. With --fix the
#       one-time backfill (Q-1094-DORMANT): fixes + files in every project with no live session
#       (session lock, or a live Claude Code process cwd'd there — skipped and reported), the
#       project this shell runs in is fixed but left for its own session to commit; with
#       --commit-push each fixed repo gets one commit (fixed message + Rule-removed trailers +
#       Co-Authored-By) and a push where an upstream exists. Repos carrying the fleet's
#       `.template-repo` marker are never fixed by a sweep (their CLAUDE.md is Category 3);
#       --skip names further projects the fix pass must leave alone (an upstream clone); both
#       are still reported. A repo mid-merge/rebase, detached, behind its fetched upstream or
#       with dirty target files is skipped and reported too. A project root carrying
#       `.fleet-conformance-skip` (content ignored) has opted out: one NOTE, nothing checked,
#       fixed or filed, by the sweep or by the per-project path; never counted as drift.
#       Filed backlog items are P2 (Q-1094-ITEMPRIO).
#       The summary names at most 10 projects per list ("+N more"); --sweep has them all.
#   --trailers [<dir>…]   the `-m 'Rule-removed: …'` arguments a commit of the rewritten
#                         manifest needs (rule-removal-guard.sh, CFG-897); default: this dir.
#   --if-due | --force | --status
#       The date-gated PROJECT_DRIFT line for cfg sessions (checks/31-project-drift.sh, the
#       pattern of fleet-drift.sh): --if-due sweeps once a day (sched-lib) and caches, then
#       renders the cache; --status renders only; silence never occurs.
# Seams (tests): PC_REGISTRY PC_CACHE PC_SELF_DIR SCHED_MARKER_DIR + the lib's.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=project-conformance-lib.sh
source "$SCRIPT_DIR/project-conformance-lib.sh"

PC_CACHE="${PC_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/cfg-agent-fleet/project-drift.status}"
PC_SELF_DIR="${PC_SELF_DIR:-$PWD}"
PC_TODAY="$(date +%Y-%m-%d)"
CO_AUTHOR="Co-Authored-By: Claude <noreply@anthropic.com>"

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ── Item helpers ─────────────────────────────────────────────────────────────

# _items_of <class> <items> → "kind: text; kind: text" for the lines of that class
_items_of() {
    printf '%s\n' "$2" | awk -F'|' -v cls="$1" '$1 == cls { printf "%s%s: %s", (n++ ? "; " : ""), $2, $3 }'
}
# _grouped <items> → "FIX kind: text; … | FILE kind: text | NOTE kind: text" (classes present only)
_grouped() {
    local c out=""
    for c in FIX FILE NOTE; do
        [ "$(_count_of "$c" "$1")" -gt 0 ] && out="${out:+$out | }$c $(_items_of "$c" "$1")"
    done
    printf '%s' "$out"
}
_texts_of() { printf '%s\n' "$2" | awk -F'|' -v cls="$1" '$1 == cls { printf "%s%s", (n++ ? "; " : ""), $3 }'; }
_count_of() { printf '%s\n' "$2" | grep -c "^$1|" || true; }

# ── --project ────────────────────────────────────────────────────────────────

do_project() {   # <dir> <name> <type> <fix> <file> <brief>
    local dir="$1" name="$2" type="$3" fix="$4" file="$5" brief="$6" items fixed="" filed="" behind=0
    items=$(pc_check "$dir" "$name" "$type")
    # MAJOR 1: the SessionStart hook runs BEFORE the startup pull. On a branch behind its fetched
    # upstream nothing is written — an untracked .githooks/pre-commit the pull also brings would
    # abort `git pull --ff-only`; the next start, after the pull, finds what is really left.
    [ "$fix$file" != "00" ] && behind=$(pc_behind_count "$dir")
    if [ "$behind" -gt 0 ]; then
        fix=0; file=0
        items="NOTE|deferred|HEAD is $behind commit(s) behind @{u}; the conformance fixes run after this session's pull"$'\n'"$items"
    fi
    if [ "$fix" -eq 1 ] && printf '%s\n' "$items" | grep -q '^FIX|'; then
        pc_fix "$dir" "$name" "$type" >/dev/null; fixed="$PC_FIXED"      # not in $(…): PC_CHANGED_FILES must survive
        items=$(pc_check "$dir" "$name" "$type")
    fi
    if [ "$file" -eq 1 ] && printf '%s\n' "$items" | grep -q '^FILE|' && [ -z "$(pc_repo_note "$dir")" ]; then
        filed=$(pc_file_backlog "$dir" "$name" "$(_texts_of FILE "$items")") || filed="FAILED"
    fi
    if [ "$brief" -eq 1 ]; then
        if [ "$behind" -gt 0 ]; then printf 'PROJECT_CONFORMANCE: deferred — %s.\n' "$(_texts_of NOTE "$(printf '%s\n' "$items" | grep '^NOTE|deferred|')")"
        else _brief_line "$dir" "$fixed" "$filed" "$items"; fi
    else
        [ -n "$fixed" ] && printf '%s\n' "$fixed"
        [ -n "$items" ] && printf '%s\n' "$items"
        [ -n "$filed" ] && printf '%s\n' "$filed"
    fi
    return 0
}

_brief_line() {   # <dir> <fixed> <filed> <items>
    local dir="$1" fixed="$2" filed="$3" items="$4" line="" tag="PROJECT_CONFORMANCE"
    if [ -n "$fixed" ]; then
        line="fixed $(_texts_of FIXED "$fixed") — commit these in this session"
        printf '%s\n' "$fixed" | grep -q '^FIXED|retired|' \
            && line="$line (the rewritten manifest needs Rule-removed trailers: bash $SCRIPT_DIR/project-conformance.sh --trailers $dir)"
        line="$line."
    fi
    case "$filed" in
        FILED\|*) line="${line:+$line }Filed backlog item ${filed#FILED|} for: $(_texts_of FILE "$items")." ;;
        FAILED)   tag="PROJECT_CONFORMANCE[WARN]"; line="${line:+$line }Could not write backlog.md for: $(_texts_of FILE "$items")." ;;
    esac
    if printf '%s\n' "$items" | grep -q '^FIX|'; then
        tag="PROJECT_CONFORMANCE[WARN]"; line="${line:+$line }Still to fix (the fix failed): $(_texts_of FIX "$items")."
    fi
    # Nothing to say prints a sentinel the check swallows: a crash is then distinguishable from silence.
    if [ -n "$line" ]; then printf '%s: %s\n' "$tag" "$line"
    elif printf '%s\n' "$items" | grep -q '^NOTE|opted-out|'; then printf 'PROJECT_CONFORMANCE: opted out (%s)\n' "$PC_OPT_OUT_MARKER"
    else printf 'PROJECT_CONFORMANCE: ok\n'; fi
    return 0
}

# ── --sweep ──────────────────────────────────────────────────────────────────

SW_REG=0; SW_OK=0; SW_FIX=0; SW_FILE=0; SW_ABSENT=0; SW_SKIP=0; SW_NOTE=0
SW_FIX_NAMES=""; SW_FILE_NAMES=""; SW_ABSENT_NAMES=""; SW_NOTE_NAMES=""; SW_LINES=(); SKIP_NAMES=""
SW_NAMES_MAX=10
# _skipped <name> — named in --skip?
_skipped() { case ",$SKIP_NAMES," in *",$1,"*) return 0 ;; esac; return 1; }
# _template_repo <dir> — a fleet template repo (the `.template-repo` marker, CFG-329): its CLAUDE.md
# is Category 3, changes go through template-push or its own session, never a sweep (MAJOR 2).
# Reported like every project, never fixed by --fix.
_template_repo() { [ -f "$1/.template-repo" ]; }
# _noted <items> — a NOTE that is a converted finding (not the repo shape itself, not an own hook)
_noted() { printf '%s\n' "$1" | grep '^NOTE|' | grep -qvE '^NOTE\|(repo|githooks)\|'; }

# _capped <comma list> → the first SW_NAMES_MAX names, then "+N more"
_capped() {
    printf '%s' "$1" | awk -v max="$SW_NAMES_MAX" -F', ' '
        { for (i = 1; i <= NF && i <= max; i++) printf "%s%s", (i > 1 ? ", " : ""), $i
          if (NF > max) printf ", +%d more", NF - max }'
}

do_sweep() {   # <fix> <commit>
    local fix="$1" commit="$2" row name path type self
    self=$(cd "$PC_SELF_DIR" 2>/dev/null && pwd -P) || self=""
    while IFS='|' read -r name path type; do
        [ -n "$name" ] || continue
        SW_REG=$((SW_REG + 1))
        if [ ! -d "$path" ]; then
            SW_ABSENT=$((SW_ABSENT + 1)); SW_ABSENT_NAMES="${SW_ABSENT_NAMES:+$SW_ABSENT_NAMES, }$name"
            SW_LINES+=("$name: ABSENT ($path)"); continue
        fi
        _sweep_one "$name" "$path" "$type" "$fix" "$commit" "$self"
    done < <(pc_registry_rows)
}

_sweep_one() {   # <name> <dir> <type> <fix> <commit> <self>
    local name="$1" dir="$2" type="$3" fix="$4" commit="$5" self="$6" items live="" fixed="" filed="" tail=""
    items=$(pc_check "$dir" "$name" "$type")
    if [ "$fix" -eq 1 ] && printf '%s\n' "$items" | grep -qE '^(FIX|FILE)\|' && [ -z "$(pc_repo_note "$dir")" ]; then
        local why=""
        if _skipped "$name"; then why="--skip"
        elif _template_repo "$dir"; then why="template repo (.template-repo) — Category 3, changes go through template-push or its own session"
        else why=$(pc_repo_state "$dir"); fi
        if [ -n "$why" ]; then
            SW_SKIP=$((SW_SKIP + 1)); SW_LINES+=("$name: SKIPPED ($why) — left alone: $(_grouped "$items")")
            _sweep_count "$name" "$items"; return 0
        fi
        if [ "$(cd "$dir" && pwd -P)" != "$self" ]; then
            live=$(pc_live_session "$dir")
            if [ "$live" != "free" ]; then
                SW_SKIP=$((SW_SKIP + 1)); SW_LINES+=("$name: LOCKED ($live) — skipped: $(_grouped "$items")")
                _sweep_count "$name" "$items"; return 0
            fi
        fi
        pc_fix "$dir" "$name" "$type" >/dev/null; fixed="$PC_FIXED"      # not in $(…): PC_CHANGED_FILES must survive
        if printf '%s\n' "$items" | grep -q '^FILE|'; then
            filed=$(pc_file_backlog "$dir" "$name" "$(_texts_of FILE "$items")" 2>/dev/null) || filed="FAILED"
            [ "$filed" = "TRACKED" ] && filed=""
        fi
        items=$(pc_check "$dir" "$name" "$type")
        if [ "$(cd "$dir" && pwd -P)" = "$self" ]; then tail=" — this session's own tree — commit it here"
        elif [ "$commit" -eq 1 ] && [ -n "$fixed$filed" ]; then tail=" — $(_commit_push "$dir" "$fixed" "$filed")"; fi
    fi
    _sweep_count "$name" "$items"
    if [ -n "$fixed$filed" ]; then
        local still; still=$(_items_of FIX "$items")
        SW_LINES+=("$name: FIXED $(_items_of FIXED "$fixed")${filed:+; filed backlog item ${filed#FILED|} for: $(_texts_of FILE "$items")}${still:+; FIX still open: $still}$tail")
    elif printf '%s\n' "$items" | grep -qE '^(FIX|FILE)\|'; then
        SW_LINES+=("$name: $(_grouped "$items")")
    elif _noted "$items"; then
        SW_LINES+=("$name: $(_grouped "$items")")      # findings nobody can fix or file: reported, never WARN
    else
        SW_OK=$((SW_OK + 1)); SW_LINES+=("$name: OK${items:+ ($(_texts_of NOTE "$items"))}")
    fi
}

_sweep_count() {   # <name> <items> — what is still open after this pass
    [ "$(_count_of FIX "$2")" -gt 0 ] && { SW_FIX=$((SW_FIX + 1)); SW_FIX_NAMES="${SW_FIX_NAMES:+$SW_FIX_NAMES, }$1"; }
    [ "$(_count_of FILE "$2")" -gt 0 ] && { SW_FILE=$((SW_FILE + 1)); SW_FILE_NAMES="${SW_FILE_NAMES:+$SW_FILE_NAMES, }$1"; }
    if ! printf '%s\n' "$2" | grep -qE '^(FIX|FILE)\|' && _noted "$2"; then
        SW_NOTE=$((SW_NOTE + 1)); SW_NOTE_NAMES="${SW_NOTE_NAMES:+$SW_NOTE_NAMES, }$1"
    fi
    return 0
}

# _commit_push <dir> <fixed> <filed> → "committed <sha>, pushed to <remote/branch>" | "…, not pushed (why)" | "commit failed"
_commit_push() {
    local dir="$1" fixed="$2" filed="$3" f args=() t sha up
    while IFS= read -r f; do [ -n "$f" ] && git -C "$dir" add -- "$f" 2>/dev/null; done <<< "$PC_CHANGED_FILES"
    [ -n "$filed" ] && git -C "$dir" add -- backlog.md 2>/dev/null
    [ -n "$(git -C "$dir" diff --cached --name-only)" ] || { printf 'nothing staged'; return 0; }
    # No machine identifier in commit text: some of these repos are public (MAJOR 2).
    args=(-m "Project conformance backfill (CFG-1094): $(_texts_of FIXED "$fixed")${filed:+; backlog item ${filed#FILED|} filed}" \
          -m "Applied by project-conformance.sh --sweep --fix --commit-push ($PC_TODAY): the mechanical items a new project receives at setup, backfilled into this registered project.")
    while IFS= read -r t; do [ -n "$t" ] && args+=(-m "$t"); done < <(pc_trailers "$dir")
    args+=(-m "$CO_AUTHOR")
    git -C "$dir" commit -q "${args[@]}" >/dev/null 2>&1 || { printf 'commit failed (see git status in %s)' "$dir"; return 0; }
    sha=$(git -C "$dir" rev-parse --short HEAD)
    up=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || { printf 'committed %s, not pushed (no upstream)' "$sha"; return 0; }
    if git -C "$dir" push -q 2>/dev/null; then printf 'committed %s, pushed to %s' "$sha" "$up"
    else printf 'committed %s, push to %s FAILED' "$sha" "$up"; fi
}

_sweep_summary() {
    local sev="" body
    [ $((SW_FIX + SW_FILE)) -gt 0 ] && sev="[WARN]"
    body="$SW_REG registered, $SW_OK conform, $SW_FIX to fix${SW_FIX_NAMES:+ ($(_capped "$SW_FIX_NAMES"))}, $SW_FILE to file${SW_FILE_NAMES:+ ($(_capped "$SW_FILE_NAMES"))}, $SW_ABSENT absent${SW_ABSENT_NAMES:+ ($(_capped "$SW_ABSENT_NAMES"))}"
    [ "$SW_NOTE" -gt 0 ] && body="$body, $SW_NOTE noted ($(_capped "$SW_NOTE_NAMES"))"
    [ "$SW_SKIP" -gt 0 ] && body="$body, $SW_SKIP skipped"
    printf 'PROJECT_DRIFT%s: %s | probed %s\n' "$sev" "$body" "$PC_TODAY"
}

# ── PROJECT_DRIFT cache + gate (pattern of fleet-drift.sh) ───────────────────

_probe_cache() {
    do_sweep 0 0
    mkdir -p "$(dirname "$PC_CACHE")" 2>/dev/null || true
    { echo "# project-drift cache — machine-local, written by project-conformance.sh"; echo "probe_date=$PC_TODAY"
      echo "line=$(_sweep_summary)"; printf 'project=%s\n' "${SW_LINES[@]}"; } > "$PC_CACHE.tmp.$$" && mv "$PC_CACHE.tmp.$$" "$PC_CACHE"
}

_render() {
    [ -f "$PC_CACHE" ] || { echo "PROJECT_DRIFT[WARN]: never probed on this machine — run 'bash $SCRIPT_DIR/project-conformance.sh --force'"; return 0; }
    local line; line=$(sed -n 's/^line=//p' "$PC_CACHE" | head -1)
    [ -n "$line" ] && echo "$line" || echo "PROJECT_DRIFT[WARN]: cache unreadable at $PC_CACHE — run 'bash $SCRIPT_DIR/project-conformance.sh --force'"
}

_gate_due()  { source "$SCRIPT_DIR/sched-lib.sh" 2>/dev/null && sched_is_due "project-drift" "daily"; }
_gate_done() { type sched_mark_done >/dev/null 2>&1 && sched_mark_done "project-drift" "daily"; }

# ── Main ─────────────────────────────────────────────────────────────────────

MODE=""; DIR=""; NAME=""; TYPE=""; FIX=0; FILE=0; BRIEF=0; COMMIT=0; DIRS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --project) MODE=project; DIR="${2:-}"; shift ;;
        --sweep|--if-due|--force|--status) MODE="${1#--}" ;;
        --trailers) MODE=trailers ;;
        --name) NAME="${2:-}"; shift ;;
        --type) TYPE="${2:-}"; shift ;;
        --fix) FIX=1 ;;
        --file-backlog) FILE=1 ;;
        --brief) BRIEF=1 ;;
        --commit-push) COMMIT=1 ;;
        --co-author) CO_AUTHOR="${2:-$CO_AUTHOR}"; shift ;;
        --skip) SKIP_NAMES="${2:-}"; shift ;;
        -h|--help) usage ;;
        -*) echo "project-conformance: unknown option '$1'" >&2; usage ;;
        *) DIRS+=("$1") ;;
    esac
    shift
done
[ "$COMMIT" -eq 1 ] && [ "$FIX" -eq 0 ] && { echo "project-conformance: --commit-push needs --fix" >&2; exit 2; }

case "$MODE" in
    project)
        [ -n "$DIR" ] && [ -d "$DIR" ] || { echo "project-conformance: --project needs a directory" >&2; exit 2; }
        if [ -z "$NAME" ]; then
            # Not a fleet project: nothing to do; the sentinel keeps a crash distinguishable from this.
            row=$(pc_registry_lookup "$DIR") || { [ "$BRIEF" -eq 1 ] && echo "PROJECT_CONFORMANCE: not a registered project"; exit 0; }
            NAME="${row%%|*}"; TYPE="${row##*|}"
        fi
        do_project "$DIR" "$NAME" "$TYPE" "$FIX" "$FILE" "$BRIEF" ;;
    sweep)
        do_sweep "$FIX" "$COMMIT"
        printf '%s\n' "${SW_LINES[@]+"${SW_LINES[@]}"}"
        _sweep_summary ;;
    trailers)
        [ ${#DIRS[@]} -gt 0 ] || DIRS=("$PWD")
        for d in "${DIRS[@]}"; do
            while IFS= read -r t; do
                [ -n "$t" ] && printf -- "-m '%s'\n" "${t//\'/\'\"\'\"\'}"
            done < <(pc_trailers "$d")
        done ;;
    force)  _probe_cache; _render ;;
    status) _render ;;
    if-due)
        if _gate_due; then _probe_cache; _gate_done; fi
        _render ;;
    *) usage ;;
esac
exit 0
