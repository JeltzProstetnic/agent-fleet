#!/usr/bin/env bash
# Check group 3b: typed inbox delivery (CFG-541) + dated-item expiry lane (CFG-543)
# Sourced after 03-inbox-services.sh by filename order; reuses INBOX / PROJECT_NAME / TASKS.
# Shared vars used: CONFIG_REPO, INBOX_MSG. Sets: INBOX_DEADLINES.
#
# NOTE: stdout from a check is a JSON contract (CFG-503). Never echo here — a single
# stray line makes CC discard the ENTIRE additionalContext payload, silently.

_INBOX="${INBOX:-$CONFIG_REPO/cross-project/inbox.md}"
[ -f "$_INBOX" ] || return 0 2>/dev/null || true
_PROJ="${PROJECT_NAME:-$(basename "$(pwd)")}"
_MINE="${TASKS:-$(grep -i -- "- \[ \].*\*\*[[:space:]]*$_PROJ[[:space:]]*\*\*" "$_INBOX" 2>/dev/null || true)}"

# ── CFG-541: type-aware delivery ────────────────────────────────────────────
# fact → write the target file now, delete the item, NO backlog entry ever.
# rule → Meta-Rules consent queue.  work → backlog.md.  fyi → read, delete.
# `fact` leads because it is the only class that is free to execute; those items
# were never hard, only unrecognisable among the expensive ones.
if [ -n "$_MINE" ]; then
    _count_type() { printf '%s\n' "$_MINE" | grep -c -- "\[$1\]" 2>/dev/null | head -1; }
    _n_fact=$(_count_type fact); _n_rule=$(_count_type rule)
    _n_work=$(_count_type work); _n_fyi=$(_count_type fyi)
    _n_untag=$(printf '%s\n' "$_MINE" | grep -cvE '\[(fact|rule|work|fyi)\]' 2>/dev/null | head -1)
    for _v in _n_fact _n_rule _n_work _n_fyi _n_untag; do
        [ -n "${!_v}" ] || eval "$_v=0"
    done

    _breakdown=""
    [ "$_n_fact"  -gt 0 ] && _breakdown="${_breakdown:+$_breakdown, }$_n_fact fact (execute now, do NOT backlog)"
    [ "$_n_rule"  -gt 0 ] && _breakdown="${_breakdown:+$_breakdown, }$_n_rule rule (needs owner consent)"
    [ "$_n_work"  -gt 0 ] && _breakdown="${_breakdown:+$_breakdown, }$_n_work work (promote to backlog)"
    [ "$_n_fyi"   -gt 0 ] && _breakdown="${_breakdown:+$_breakdown, }$_n_fyi fyi (read, delete)"
    [ "$_n_untag" -gt 0 ] && _breakdown="${_breakdown:+$_breakdown, }$_n_untag untagged (pre-CFG-541; classify then dispatch)"

    # fact first, then the other tagged classes, then untagged legacy items.
    _ordered=$( { printf '%s\n' "$_MINE" | grep -- '\[fact\]' 2>/dev/null || true
                  printf '%s\n' "$_MINE" | grep -E -- '\[(rule|work|fyi)\]' 2>/dev/null || true
                  printf '%s\n' "$_MINE" | grep -vE -- '\[(fact|rule|work|fyi)\]' 2>/dev/null || true
                } | grep -v '^$' || true )

    INBOX_MSG="INBOX TASKS for $_PROJ [INBOX_TYPES: $_breakdown]: $_ordered${INBOX_MSG:+ | $INBOX_MSG}"
fi

# ── CFG-543: dated-item expiry lane ─────────────────────────────────────────
# Urgency is a property of the calendar and no priority number can carry it: a
# conference submission deadline decayed from 17 days out to 3 in a queue sorted by
# nothing. The discriminator between a deadline and filing noise is TENSE — every
# item carries "from <proj> <machine> <date>" in the past, so only FUTURE dates
# enter the lane. Ordered soonest-first, deliberately independent of the P-number.
# Anchor on TODAY'S MIDNIGHT, not on now: `date -d <YYYY-MM-DD> +%s` yields midnight,
# so comparing it against the current wall clock truncates a genuine 9-day gap to "8d".
# Days remaining must be calendar days — a deadline does not arrive part-way through.
_today_s=$(date -d "$(date +%Y-%m-%d)" +%s 2>/dev/null || echo 0)
if [ "$_today_s" -gt 0 ]; then
    # CFG-542: scan the whole corpus (per-project files + legacy), not just inbox.md,
    # or a deadline silently stops being seen the moment its item is migrated.
    _deadline_src() {
        if command -v inbox_all_items >/dev/null 2>&1; then
            inbox_all_items 2>/dev/null
        else
            cat "$_INBOX" 2>/dev/null
        fi
    }
    INBOX_DEADLINES=$(_deadline_src | awk -v now="$_today_s" '
        /^- \[ \]/ {
            line = $0; best = ""
            s = line
            while (match(s, /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
                d = substr(s, RSTART, RLENGTH)
                cmd = "date -d " d " +%s 2>/dev/null"
                cmd | getline ts; close(cmd)
                if (ts + 0 > now && (best == "" || ts + 0 < bestts)) { best = d; bestts = ts + 0 }
                s = substr(s, RSTART + RLENGTH)
            }
            if (best != "") {
                days = int((bestts - now) / 86400)
                proj = ""
                if (match(line, /\*\*[^*]+\*\*/)) proj = substr(line, RSTART + 2, RLENGTH - 4)
                brief = substr(line, 1, 150)
                printf "%010d|%dd left (%s) %s: %s\n", bestts, days, best, proj, brief
            }
        }' 2>/dev/null | sort | cut -d'|' -f2- | head -8 | tr '\n' '~' | sed 's/~/ | /g; s/ | $//')

    if [ -n "${INBOX_DEADLINES:-}" ]; then
        INBOX_MSG="${INBOX_MSG:+$INBOX_MSG | }DEADLINE: $INBOX_DEADLINES"
    fi
fi
