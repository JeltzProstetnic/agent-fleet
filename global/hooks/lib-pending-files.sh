#!/usr/bin/env bash
# lib-pending-files.sh — the docs/pending-*.md scan behind check 6a.5: PENDING_FILES,
# ACT_PENDING, STALE_PENDING, UNTRACKED_PENDING, DANGLING_PENDING, and (CFG-948) the
# work-block fields WORK_MALFORMED / WORK_DONE_CONFLICT. Moved out of
# checks/06a-session-state.sh on 2026-11-11 so that check stays under the 100-line
# threshold (CFG-171); the pre-existing logic is unchanged.
#
# Reads PROJECT_DIR and CONFIG_REPO; appends to WARNINGS and IDENTITY_MSG.
#   pending_files_scan   — fills _pending_list _act_files _stale_files _untracked_files
#                          _work_malformed _work_done_conflict (and _stale_set, _dangling)
#   pending_files_report — writes the WARNINGS fields and the PENDING_FILES identity field
#
# Stale-pending reconciliation (CFG-620): manage-pending.sh --stale-check resolves each
# act/present file's Tracked-by IDs against backlog.md STATE — STALE only when every
# ID's own line is "- [x]". It never reads prose ("shipped", a commit hash) as evidence;
# that guess was wrong every recorded time. Stale files go to a SEPARATE STALE_PENDING
# field so the agent verifies-before-presenting instead of re-listing shipped work as
# live ACT/PENDING. Files with no real Tracked-by stay live and are named under
# UNTRACKED_PENDING (a different problem); a supersession pointer to a file that does
# not exist is DANGLING_PENDING (a data-loss signal). Genuinely-open files keep
# byte-identical ACT_PENDING/PENDING_FILES output — unless they carry a Work: block,
# which is appended as "; stage/status: next" (CFG-948), or "; stage/status [regulated]: next"
# when the block carries the optional rigor=regulated field (CFG-953).

source "$(dirname "${BASH_SOURCE[0]}")/lib-pending-due.sh" 2>/dev/null || true
source "$(dirname "${BASH_SOURCE[0]}")/lib-pending-work.sh" 2>/dev/null || true

# Returns 0 if the given filename appears as a STALE: / UNTRACKED: line in the set.
_is_stale_pending()     { [ -n "$_stale_set" ] && printf '%s\n' "$_stale_set" | grep -qF "STALE: $1"; }
_is_untracked_pending() { [ -n "$_stale_set" ] && printf '%s\n' "$_stale_set" | grep -qF "UNTRACKED: $1"; }

# CFG-948: parse the Work: block of one file into _pf_work (compact form, or "") and
# the warning lists. Runs in the caller's shell so _pw_status is visible here.
_pending_work_fields() {   # <file> <basename> <action>
    local _pf_rc=0
    _pf_work=""
    type pending_work_parse >/dev/null 2>&1 || return 0
    pending_work_parse "$1" || _pf_rc=$?
    [ "$_pf_rc" = 1 ] && return 0
    _pf_work=$(pending_work_format) || true
    if [ "$_pf_rc" = 2 ]; then
        _work_malformed="${_work_malformed:+$_work_malformed, }$2 (${_pf_work#MALFORMED: })"
        _pf_work=""
    elif [ "$_pw_status" = "done" ]; then
        case "$3" in act|present|await-user-decision)
            _work_done_conflict="${_work_done_conflict:+$_work_done_conflict, }$2 (Action: $3)" ;;
        esac
    fi
}

pending_files_scan() {
    _stale_set=""; _pending_list=""; _act_files=""; _stale_files=""; _untracked_files=""
    _work_malformed=""; _work_done_conflict=""
    [ -d "$PROJECT_DIR/docs" ] || return 0
    local _manage_pending="${CONFIG_REPO:-}/setup/scripts/manage-pending.sh"
    if [ -f "$_manage_pending" ]; then
        _stale_set=$(bash "$_manage_pending" --stale-check --project-dir "$PROJECT_DIR" 2>/dev/null || true)
    fi
    local _pf _pf_base _action _pf_label _pf_sched _pf_due _pf_work
    for _pf in "$PROJECT_DIR"/docs/pending-*.md; do
        [ -f "$_pf" ] || continue
        _pf_base="$(basename "$_pf")"
        # Accept BOTH header forms (CFG-482). Every real pending file writes
        # `<!-- Action: x -->` so the header stays invisible in rendered markdown;
        # the bare form only ever existed in fixtures. Strip the comment markers
        # first, then take the single word after `Action:`.
        _action=$(head -5 "$_pf" | sed -e 's/<!--//' -e 's/-->//' \
            | sed -n 's/^[[:space:]]*Action:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
        if _is_stale_pending "$_pf_base"; then
            # Route stale act/present files away from the loud channels.
            _stale_files="${_stale_files:+$_stale_files, }$_pf_base (${_action:-triage})"
            continue
        fi
        # CFG-896: an act file due in the future is scheduled, not immediate work.
        _pf_label="${_action:-triage}"; _pf_sched=""
        if [ "$_action" = "act" ] && type pending_due_date >/dev/null 2>&1; then
            _pf_due=$(pending_due_date "$_pf")
            if [ -n "$_pf_due" ] && [[ "$_pf_due" > "$(date +%F)" ]]; then _pf_sched=1; _pf_label="scheduled $_pf_due"; fi
        fi
        _pending_work_fields "$_pf" "$_pf_base" "$_action"
        _pending_list="${_pending_list:+$_pending_list, }$_pf_base ($_pf_label${_pf_work:+; $_pf_work})"
        if [ "$_action" = "act" ] && [ -z "$_pf_sched" ]; then
            _act_files="${_act_files:+$_act_files, }$_pf_base${_pf_work:+ ($_pf_work)}"
        fi
        if _is_untracked_pending "$_pf_base"; then
            _untracked_files="${_untracked_files:+$_untracked_files, }$_pf_base"
        fi
    done
}

pending_files_report() {
    if [ -n "$_act_files" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }ACT_PENDING: These pending files require IMMEDIATE execution before any user task: $_act_files — read them and execute (loading protocol step 0b)."
    fi
    if [ -n "$_stale_files" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }STALE_PENDING: every Tracked-by ID is [x] in backlog.md for: $_stale_files — check those IDs, then demote (act/present → reference, or delete). Not live work unless an ID turns out open."
    fi
    if [ -n "$_untracked_files" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }UNTRACKED_PENDING: act/present files with no Tracked-by: $_untracked_files — file a backlog item and add the header."
    fi
    if [ -n "$_work_malformed" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }WORK_MALFORMED: $_work_malformed — unparseable Work: block; fix it to <!-- Work: stage=<word>; status=<one of open, blocked, awaiting-proof, done>; next=<one line>; approved=<YYYY-MM-DD who, or none>; rigor=regulated --> (fields in any order, ;-separated; rigor is optional and regulated is its only value)."
    fi
    if [ -n "$_work_done_conflict" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }WORK_DONE_CONFLICT: $_work_done_conflict — status=done on a still-live pending file; demote it (Action: reference, or delete) or reopen the work. A done item is not live work."
    fi
    # Dangling supersession pointers (any action, reference included).
    _dangling=""
    if [ -n "$_stale_set" ]; then
        _dangling=$(printf '%s\n' "$_stale_set" | sed -n 's/^DANGLING: \([^ ]*\) → \([^ ]*\).*/\1 → \2/p' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    fi
    if [ -n "$_dangling" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }DANGLING_PENDING: supersession pointer to a file that does not exist (possible data loss — check git log for it): $_dangling"
    fi
    if [ -n "$_pending_list" ]; then
        IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }PENDING_FILES: $_pending_list"
    else
        IDENTITY_MSG="${IDENTITY_MSG:+$IDENTITY_MSG | }PENDING_FILES: none"
    fi
}
