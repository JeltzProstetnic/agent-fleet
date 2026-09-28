#!/usr/bin/env bash
# Check group 21: fleet issue tracker (daily)
#
# GitHub issues are the PREFERRED intake channel for fleet users, which only
# means anything if somebody reads them. GH#6 was filed 2026-08-13, fixed
# 2026-08-23 from an internal duplicate, and still had zero comments four weeks
# later — because nothing in SessionStart ever looked. This makes "somebody
# reported a bug" mechanically visible at the one moment a session is
# guaranteed to look at something. See CFG-589.
#
# Silent on every failure path: no network, rate limit, junk response, missing
# python3. A startup check that can break a session is worse than no check.
# Shared vars used: PROJECT_DIR, CONFIG_REPO, WARNINGS

_FI_PROJECT_DIR="${PROJECT_DIR:-}"
_FI_CONFIG_REPO="${CONFIG_REPO:-}"

# Only the config repo's own sessions own the fleet tracker. Every other project
# would pay a network call for somebody else's inbox.
[ -n "$_FI_PROJECT_DIR" ] && [ "$_FI_PROJECT_DIR" = "$_FI_CONFIG_REPO" ] \
    || return 0 2>/dev/null || true

command -v python3 >/dev/null 2>&1 || return 0 2>/dev/null || true

# No default (owner decision 2026-09-28, CFG-700 (3)): an installation that has not named its
# own tracker makes no network call. The config repo sets FLEET_ISSUE_REPO in its
# settings env; a downstream install would otherwise poll somebody else's repo.
_FI_REPO="${FLEET_ISSUE_REPO:-}"
[ -n "$_FI_REPO" ] || return 0 2>/dev/null || true

# An issue younger than this has not been ignored yet — flagging it would train
# the reader to skim past the field.
_FI_UNANSWERED_DAYS="${FLEET_ISSUES_UNANSWERED_DAYS:-1}"

# Daily gate — same pattern as check 17.
_fi_sched_lib="${_FI_CONFIG_REPO}/setup/scripts/sched-lib.sh"
if [ -f "$_fi_sched_lib" ]; then
    source "$_fi_sched_lib"
    sched_is_due "fleet-issue-check" "daily" || return 0 2>/dev/null || true
else
    # fallback inline marker — never a bare /tmp (GH#13: read-only in the CC sandbox)
    _fi_gate="${SCHED_MARKER_DIR:-${TMPDIR:-/tmp}}""/.fleet-issue-check-$(date +%Y-%m-%d)"
    [ ! -f "$_fi_gate" ] || return 0 2>/dev/null || true
fi

# Fetch is injectable so the tests never touch the network.
_fi_json=""
if [ -n "${FLEET_ISSUES_FETCH_CMD:-}" ]; then
    _fi_json=$("$FLEET_ISSUES_FETCH_CMD" 2>/dev/null) || _fi_json=""
elif command -v curl >/dev/null 2>&1; then
    _fi_json=$(curl -sS --max-time 4 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${_FI_REPO}/issues?state=open&per_page=20" \
        2>/dev/null) || _fi_json=""
fi

# Mark done regardless of outcome — a rate-limited day should not retry every
# session, which is how a cheap check turns into a startup tax.
if type sched_mark_done &>/dev/null; then
    sched_mark_done "fleet-issue-check" "daily"
elif [ -n "${_fi_gate:-}" ]; then
    touch "$_fi_gate" 2>/dev/null || true
fi

[ -n "$_fi_json" ] || return 0 2>/dev/null || true

_fi_summary=$(printf '%s' "$_fi_json" | python3 -c "
import json, sys, datetime
try:
    items = json.load(sys.stdin)
except Exception:
    sys.exit()
if not isinstance(items, list):
    sys.exit()
# The issues endpoint returns pull requests too; a PR is not a bug report.
issues = [i for i in items if isinstance(i, dict) and 'pull_request' not in i]
if not issues:
    sys.exit()
now = datetime.datetime.now(datetime.timezone.utc)
threshold = int('${_FI_UNANSWERED_DAYS}')
parts = []
for i in issues:
    try:
        created = datetime.datetime.strptime(i['created_at'], '%Y-%m-%dT%H:%M:%SZ')
        created = created.replace(tzinfo=datetime.timezone.utc)
        age = (now - created).days
    except Exception:
        continue
    title = (i.get('title') or '')[:60]
    tag = ', no reply' if (i.get('comments', 0) == 0 and age >= threshold) else ''
    parts.append('#%s \"%s\" (%dd%s)' % (i.get('number'), title, age, tag))
if not parts:
    sys.exit()
print('%d open — %s' % (len(issues), '; '.join(parts[:6])))
" 2>/dev/null)

[ -n "$_fi_summary" ] || return 0 2>/dev/null || true

WARNINGS="${WARNINGS:+$WARNINGS | }FLEET_ISSUES: ${_fi_summary} on ${_FI_REPO}. Answer or close anything flagged above before other work — an unanswered report is the channel failing, not the reporter."
