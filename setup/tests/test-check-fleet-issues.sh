#!/usr/bin/env bash
# Tests for global/hooks/checks/21-fleet-issues.sh
#
# WHY THIS CHECK EXISTS (CFG-589). agent-fleet GH#6 was filed by an outside user
# on 2026-08-13, fixed on 2026-08-23 from an internal duplicate, and still had
# zero comments on 2026-09-11 — four weeks with the reporter never told. Nothing
# in SessionStart ever looked at the issue tracker, so "somebody reported this"
# and "nobody reported anything" were indistinguishable at the only moment a
# session is guaranteed to look at anything. MG's ruling: GitHub issues are the
# PREFERRED intake channel for fleet users, which only holds if the channel is
# actually read.
#
# The check must never cost a session anything when the network is absent, so
# every failure path is silent — the tests below pin that as hard as they pin
# the reporting.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "SessionStart check 21: fleet issue tracker"

CHECK="$REPO_ROOT/global/hooks/checks/21-fleet-issues.sh"

# Run the module standalone with a controlled environment. Returns WARNINGS.
# A fetch command is injected so no test ever touches the network.
run_fleet_issues() {
    local project_dir="$1" config_repo="$2" fetch_cmd="$3"
    local marker_dir="${4:-$TEST_TMPDIR/markers-$RANDOM}"
    mkdir -p "$marker_dir"
    (
        PROJECT_DIR="$project_dir"
        CONFIG_REPO="$config_repo"
        WARNINGS=""
        FLEET_ISSUES_FETCH_CMD="$fetch_cmd"
        SCHED_MARKER_DIR="$marker_dir"
        # FI_TEST_REPO unset → a configured tracker; set to "" → none configured.
        if [ "${FI_TEST_REPO+set}" = set ]; then FLEET_ISSUE_REPO="$FI_TEST_REPO"
        else FLEET_ISSUE_REPO="example-owner/example-fleet"; fi
        # shellcheck disable=SC1090
        source "$CHECK"
        printf '%s' "$WARNINGS"
    )
}

# A fetch stub that prints a fixture file.
make_fetch_stub() {
    local fixture="$1"
    local stub="$TEST_TMPDIR/fetch-stub-$RANDOM.sh"
    printf '#!/usr/bin/env bash\ncat %q\n' "$fixture" > "$stub"
    chmod +x "$stub"
    printf '%s' "$stub"
}

# GitHub's issues payload, trimmed to the fields the check reads.
# `days_ago` is rendered into created_at so age assertions are stable.
make_issues_fixture() {
    local file="$TEST_TMPDIR/issues-$RANDOM.json"
    python3 - "$file" "$@" << 'PY'
import json, sys, datetime
out, spec = sys.argv[1], sys.argv[2:]
items = []
for s in spec:
    num, days, comments, title = s.split(":", 3)
    created = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=int(days))
    items.append({
        "number": int(num),
        "title": title,
        "comments": int(comments),
        "created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "user": {"login": "someone"},
    })
json.dump(items, open(out, "w"))
PY
    printf '%s' "$file"
}

# ── The reporting case this whole check exists for ───────────────────────────

test_unanswered_issue_is_named() {
    local cfg="$TEST_TMPDIR/cfg-a"; mkdir -p "$cfg"
    local fx; fx=$(make_issues_fixture "6:29:0:First-run mode never exits")
    local out; out=$(run_fleet_issues "$cfg" "$cfg" "$(make_fetch_stub "$fx")")

    assert_contains "$out" "FLEET_ISSUES:" "must emit a FLEET_ISSUES field"
    assert_contains "$out" "#6" "must name the issue number"
    assert_contains "$out" "29d" "must state how long it has waited"
    assert_contains "$out" "no reply" "an issue with zero comments must be called out as unanswered"
}
run_test "names an open issue that nobody has replied to" test_unanswered_issue_is_named

test_answered_issue_is_counted_not_flagged() {
    local cfg="$TEST_TMPDIR/cfg-b"; mkdir -p "$cfg"
    local fx; fx=$(make_issues_fixture "4:30:2:Answered already")
    local out; out=$(run_fleet_issues "$cfg" "$cfg" "$(make_fetch_stub "$fx")")

    assert_contains "$out" "1 open" "an answered issue still counts toward the open total"
    assert_not_contains "$out" "no reply" "an issue with comments must not be reported as unanswered"
}
run_test "an answered issue counts but is not flagged" test_answered_issue_is_counted_not_flagged

test_fresh_issue_is_not_flagged_as_ignored() {
    local cfg="$TEST_TMPDIR/cfg-c"; mkdir -p "$cfg"
    local fx; fx=$(make_issues_fixture "9:0:0:Filed minutes ago")
    local out; out=$(run_fleet_issues "$cfg" "$cfg" "$(make_fetch_stub "$fx")")

    assert_contains "$out" "1 open" "a brand-new issue is still an open issue"
    assert_not_contains "$out" "no reply" "an issue filed today has not been ignored yet"
}
run_test "an issue filed today is not shamed as unanswered" test_fresh_issue_is_not_flagged_as_ignored

# ── Silence cases. Each of these used to be the easy way to break a session. ──

test_no_open_issues_is_silent() {
    local cfg="$TEST_TMPDIR/cfg-d"; mkdir -p "$cfg"
    local fx="$TEST_TMPDIR/empty.json"; echo '[]' > "$fx"
    local out; out=$(run_fleet_issues "$cfg" "$cfg" "$(make_fetch_stub "$fx")")

    assert_eq "" "$out" "an empty tracker must say nothing at all"
}
run_test "no open issues: silent" test_no_open_issues_is_silent

test_fetch_failure_is_silent() {
    local cfg="$TEST_TMPDIR/cfg-e"; mkdir -p "$cfg"
    local stub="$TEST_TMPDIR/failing-fetch.sh"
    printf '#!/usr/bin/env bash\nexit 7\n' > "$stub"; chmod +x "$stub"
    local out; out=$(run_fleet_issues "$cfg" "$cfg" "$stub")

    assert_eq "" "$out" "an offline or rate-limited fetch must never produce output"
}
run_test "fetch failure (offline, rate-limited): silent" test_fetch_failure_is_silent

test_garbage_response_is_silent() {
    local cfg="$TEST_TMPDIR/cfg-f"; mkdir -p "$cfg"
    local fx="$TEST_TMPDIR/garbage.json"; printf 'not json at all' > "$fx"
    local out; out=$(run_fleet_issues "$cfg" "$cfg" "$(make_fetch_stub "$fx")")

    assert_eq "" "$out" "an unparseable response must never produce output"
}
run_test "unparseable response: silent" test_garbage_response_is_silent

test_pull_requests_are_excluded() {
    # GitHub's issues endpoint returns PRs too; they carry a pull_request key.
    local cfg="$TEST_TMPDIR/cfg-g"; mkdir -p "$cfg"
    local fx="$TEST_TMPDIR/withpr.json"
    python3 - "$fx" << 'PY'
import json, sys, datetime
c = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=40)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump([{"number": 11, "title": "a pull request", "comments": 0, "created_at": c,
            "user": {"login": "x"}, "pull_request": {"url": "..."}}], open(sys.argv[1], "w"))
PY
    local out; out=$(run_fleet_issues "$cfg" "$cfg" "$(make_fetch_stub "$fx")")

    assert_eq "" "$out" "a pull request is not an issue report and must not be counted"
}
run_test "pull requests are not counted as issues" test_pull_requests_are_excluded

# ── Scope and cost ───────────────────────────────────────────────────────────

test_silent_outside_the_config_repo() {
    local cfg="$TEST_TMPDIR/cfg-h"; mkdir -p "$cfg"
    local other="$TEST_TMPDIR/some-other-project"; mkdir -p "$other"
    local fx; fx=$(make_issues_fixture "6:29:0:Would have fired")
    local out; out=$(run_fleet_issues "$other" "$cfg" "$(make_fetch_stub "$fx")")

    assert_eq "" "$out" "the fleet tracker is not every project's business — only the config repo's"
}
run_test "silent in projects other than the config repo" test_silent_outside_the_config_repo

# Owner decision 2026-09-28 (CFG-700 (3)): the default must be EMPTY. A hardcoded tracker made
# every downstream install, corporate ones included, call github.com daily about
# somebody else's repo. Only an installation that names its tracker checks it.
test_no_configured_tracker_is_silent_and_offline() {
    local cfg="$TEST_TMPDIR/cfg-j"; mkdir -p "$cfg"
    local sentinel="$TEST_TMPDIR/fetched-$RANDOM"
    local stub="$TEST_TMPDIR/fetch-sentinel-$RANDOM.sh"
    printf '#!/usr/bin/env bash\ntouch %q\necho "[]"\n' "$sentinel" > "$stub"; chmod +x "$stub"
    local out; out=$(FI_TEST_REPO="" run_fleet_issues "$cfg" "$cfg" "$stub")
    assert_eq "" "$out" "no FLEET_ISSUE_REPO configured: nothing to report"
    local fetched="no"; [ -e "$sentinel" ] && fetched="yes"
    assert_eq "no" "$fetched" "no FLEET_ISSUE_REPO configured: the tracker must not be fetched at all"
}
run_test "no configured tracker: silent, and no network call" test_no_configured_tracker_is_silent_and_offline

test_configured_tracker_is_named_in_report() {
    local cfg="$TEST_TMPDIR/cfg-k"; mkdir -p "$cfg"
    local fx; fx=$(make_issues_fixture "6:29:0:Named repo")
    local out; out=$(FI_TEST_REPO="acme/fleet" run_fleet_issues "$cfg" "$cfg" "$(make_fetch_stub "$fx")")
    assert_contains "$out" "acme/fleet" "the report names the tracker it actually read"
}
run_test "configured tracker is the one reported" test_configured_tracker_is_named_in_report

test_daily_gate_suppresses_the_second_run() {
    local cfg="$TEST_TMPDIR/cfg-i"; mkdir -p "$cfg"
    local markers="$TEST_TMPDIR/markers-shared"; mkdir -p "$markers"
    local fx; fx=$(make_issues_fixture "6:29:0:Only once a day")
    local stub; stub=$(make_fetch_stub "$fx")

    local first second
    first=$(run_fleet_issues "$cfg" "$cfg" "$stub" "$markers")
    second=$(run_fleet_issues "$cfg" "$cfg" "$stub" "$markers")

    assert_contains "$first" "#6" "the first run of the day reports"
    assert_eq "" "$second" "the second run of the day must not hit the network again"
}
run_test "daily gate: reports once per day, not once per session" test_daily_gate_suppresses_the_second_run

suite_summary
