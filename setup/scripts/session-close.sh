#!/usr/bin/env bash
# session-close.sh — `afx session-close`: the command steps of the shutdown checklist in one verb
# (CFG-1093 P-SHUTDOWN; decided Q-1093-SHUTDOWN 2026-11-25, Q-SC-ORDER / -COMMIT / -FAIL 2026-11-26).
#
# Usage: session-close.sh [--deadline "…"] [project-dir]        (project-dir defaults to .)
#
# Run it after every judgement step of the checklist — work products, pending files, session-context,
# the handover and its `## Next Session Task`, decisions, inbox, strategy and machine files. It never
# commits or pushes (Q-SC-COMMIT): rotation changes files, so the agent commits and pushes after it.
#
# Steps, in order:
#   1 clean-permissions.sh                              warn on failure and continue
#   2 dashboard-row.sh <project> --auto [--deadline …]  warn on failure and continue; skipped when the
#                                                       dir has no dashboard row
#   3 handover-check.sh <dir>                           GATE — a gap refuses; nothing below runs
#   4 rotate-session.sh <dir>                           GATE (exit 3 = another live session holds it);
#                                                       skipped when the context is already rotated
#   5 sync.sh deploy                                    skipped when another live session holds the config
#                                                       repo, and fail-closed when that cannot be told
#                                                       (lib-cfg-held.sh, as the SessionEnd hook); warns
#   6 anti-lockout-check.sh [--live-only]               GATE; runs whenever step 5 ran. AFTER deploy, so it
#                                                       checks the live files the next session loads
#                                                       (anti-lockout-check.sh defaults to them) — Q-SC-ORDER
#                                                       --live-only outside the config repo: its check 10
#                                                       gates on cfg's own uncommitted Tier-2 edits
# Re-running after a stop is safe: steps 1–2 are idempotent and step 4 skips a rotated context.
#
# Exit: 0 all passed · 1 a gate refused · 2 usage · 4 finished with warnings.
# Test overrides: SC_CLEAN_PERMISSIONS SC_DASHBOARD_ROW SC_HANDOVER_CHECK SC_ROTATE SC_SYNC
# SC_ANTI_LOCKOUT (script paths, run with bash); SC_HELD_CHECK (a script whose exit code stands for
# check_lock's answer on the config repo); DASHBOARD_CACHE.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_REPO="${CONFIG_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CACHE="${DASHBOARD_CACHE:-$CONFIG_REPO/cross-project/dashboard-cache.md}"

CLEAN="${SC_CLEAN_PERMISSIONS:-$SCRIPT_DIR/clean-permissions.sh}"
ROW="${SC_DASHBOARD_ROW:-$SCRIPT_DIR/dashboard-row.sh}"
HANDOVER="${SC_HANDOVER_CHECK:-$SCRIPT_DIR/handover-check.sh}"
ROTATE="${SC_ROTATE:-$SCRIPT_DIR/rotate-session.sh}"
SYNC="${SC_SYNC:-$CONFIG_REPO/sync.sh}"
ANTI="${SC_ANTI_LOCKOUT:-$SCRIPT_DIR/anti-lockout-check.sh}"

usage() {
    sed -n '5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

DEADLINE="" HAVE_DEADLINE=0 DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --deadline) [[ $# -ge 2 ]] || usage; DEADLINE="$2"; HAVE_DEADLINE=1; shift 2 ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) [[ -z "$DIR" ]] || usage; DIR="$1"; shift ;;
    esac
done
DIR="${DIR:-.}"
[[ -d "$DIR" ]] || { echo "session-close: no such directory: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

WARNINGS=()
say()  { printf 'session-close: %s\n' "$*"; }
warn() { WARNINGS+=("$1"); say "WARN  $1"; }
indent() { sed 's/^/    /'; }
last_line() { awk 'NF { l = $0 } END { print l }'; }

refuse() {  # <reason> — a gate refused: stop here
    say "REFUSED — $1"
    say "nothing after this step ran; fix it, then run afx session-close again (re-running is safe)"
    exit 1
}

step_permissions() {
    local out rc=0
    out=$(bash "$CLEAN" 2>&1) || rc=$?
    if (( rc == 0 )); then say "1 permissions: ok — $(last_line <<<"$out")"
    else warn "1 permissions: clean-permissions.sh exited $rc"; indent <<<"$out" | tail -20; fi
}

step_dashboard() {
    local project out rc=0 args
    # shellcheck source=lib-dashboard.sh
    source "$SCRIPT_DIR/lib-dashboard.sh"
    if ! project=$(dashboard_project_for_dir "$CACHE" "$DIR"); then
        say "2 dashboard: skipped — no dashboard row has the path $DIR"
        return 0
    fi
    args=("$project" --auto)
    (( HAVE_DEADLINE )) && args+=(--deadline "$DEADLINE")
    out=$(bash "$ROW" "${args[@]}" 2>&1) || rc=$?
    if (( rc == 0 )); then say "2 dashboard: ok — $(last_line <<<"$out")"
    else warn "2 dashboard: dashboard-row.sh $project exited $rc"; indent <<<"$out" | tail -20; fi
}

step_handover() {
    local out rc=0
    out=$(bash "$HANDOVER" "$DIR" 2>&1) || rc=$?
    if (( rc != 0 )); then
        indent <<<"$out"
        refuse "3 handover: Recovery Instructions items not carried into the handover (listed above); carry them into the handover file or its Next Session Task section — rotation not run"
    fi
    say "3 handover: ok — every Recovery Instructions item is carried"
}

# Context state (rotate-session.sh:128-131's own tests): "rotated" = no Session Goal, no `- [x]` item and
# an empty Key Decisions section; "goalless" = content but no goal, which rotation would drop silently.
context_state() {
    local f="$DIR/session-context.md" goal done_ dec
    [[ -s "$f" ]] || { echo rotated; return; }
    goal=$(sed -n 's/.*\*\*Session Goal\*\*: \(.\+\)/\1/p' "$f" | head -1)
    done_=$(grep -i '^\s*- \[x\]' "$f" | head -1)
    dec=$(awk '/^##+ Key Decisions/{f=1; next} /^## /{f=0} f' "$f" | sed '/^[[:space:]]*$/d' | head -1)
    if [[ -n "$goal" ]]; then echo populated
    elif [[ -n "$done_$dec" ]]; then echo goalless
    else echo rotated; fi
}

step_rotate() {
    local out rc=0
    case "$(context_state)" in
        rotated)  say "4 rotate: skipped — already rotated (session-context.md has no goal, items or decisions)"
                  return 0 ;;
        goalless) refuse "4 rotate: session-context.md has completed items or decisions but no Session Goal — fill in the goal (rotation would archive nothing)" ;;
    esac
    out=$(bash "$ROTATE" "$DIR" 2>&1) || rc=$?
    case "$rc" in
        0) say "4 rotate: ok — $(last_line <<<"$out")" ;;
        3) indent <<<"$out"; refuse "4 rotate: another live session holds $DIR (rotate-session.sh exit 3) — context left intact" ;;
        *) indent <<<"$out"; refuse "4 rotate: rotate-session.sh exited $rc — context left intact" ;;
    esac
}

# check_lock's answer for the config repo: 0 free, 1 ours, 2/3 another live session, else unknown.
held_rc() {
    if [[ -n "${SC_HELD_CHECK:-}" ]]; then
        bash "$SC_HELD_CHECK" "$CONFIG_REPO" >/dev/null 2>&1
        return $?
    fi
    local lib="$CONFIG_REPO/global/hooks/lib-cfg-held.sh"
    [[ -f "$lib" ]] || return 5
    ( set +u
      # shellcheck source=../../global/hooks/lib-cfg-held.sh
      source "$lib" >/dev/null 2>&1 || exit 5
      command -v _cfg_held_check_lock >/dev/null 2>&1 || exit 5
      _cfg_held_check_lock "$CONFIG_REPO" )
}

DEPLOY_RAN=0
step_deploy() {
    local out rc=0 h=0
    held_rc || h=$?
    case "$h" in
        0|1) ;;
        2|3) say "5 deploy: skipped — the config repo is held by another live session (it deploys at its own shutdown); anti-lockout skipped with it"
             return 0 ;;
        *)   warn "5 deploy: skipped — could not tell whether another live session holds the config repo (check_lock $h), so nothing was deployed (fail closed); anti-lockout skipped with it"
             return 0 ;;
    esac
    DEPLOY_RAN=1
    out=$(cd "$CONFIG_REPO" && bash "$SYNC" deploy 2>&1) || rc=$?
    if (( rc == 0 )); then say "5 deploy: ok — sync.sh deploy exited 0"
    else warn "5 deploy: sync.sh deploy exited $rc — its output is below; fix the cause before ending the session"
         indent <<<"$out" | tail -20; fi
}

# Outside the config repo only the checks of the live files run (--live-only): check 10 asks whether
# the config repo's own uncommitted Tier-2 edits had an E2E run, which only a cfg session can answer.
step_anti_lockout() {
    (( DEPLOY_RAN )) || return 0
    local out rc=0 args=() repo_real
    repo_real="$(cd "$CONFIG_REPO" 2>/dev/null && pwd -P)"
    [[ "$(cd "$DIR" && pwd -P)" == "$repo_real" ]] || args=(--live-only)
    out=$(bash "$ANTI" ${args[@]+"${args[@]}"} 2>&1) || rc=$?
    if (( rc != 0 )); then
        indent <<<"$out" | tail -30
        refuse "6 anti-lockout: anti-lockout-check.sh ${args[*]:+${args[*]} }exited $rc — fix the FAIL lines above before ending the session"
    fi
    say "6 anti-lockout: ok${args[*]:+ (${args[*]})} — $(last_line <<<"$out")"
}

step_permissions
step_dashboard
step_handover
step_rotate
step_deploy
step_anti_lockout

if (( ${#WARNINGS[@]} > 0 )); then
    say "finished with ${#WARNINGS[@]} warning(s) — read them above; then commit and push (session-close does not)"
    exit 4
fi
say "done — now commit and push (session-close does not)"
exit 0
