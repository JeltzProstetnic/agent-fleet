#!/usr/bin/env bash
# Tests for setup/scripts/fleet-drift.sh + global/hooks/checks/22-fleet-drift.sh (CFG-615)
# Hermetic: fixture git repos under $TEST_TMPDIR, network seams overridden, zero live
# network calls. The paradigm guard (case 4) asserts a SEVERE probe never touches the
# sub-fleet — observation only, no auto-reconcile.
source "$(dirname "$0")/test-helpers.sh"

suite_header "fleet-drift (FLEET_DRIFT head-vantage probe + check 22)"

FD_SCRIPT="$REPO_ROOT/setup/scripts/fleet-drift.sh"
FD_CHECK="$REPO_ROOT/global/hooks/checks/22-fleet-drift.sh"

# ── Fixture builders ─────────────────────────────────────────────────────────

_reset_seams() {
    # Env assignments before a bash function call PERSIST after it returns —
    # clear the optional seams so one test cannot contaminate the next.
    unset FLEET_DRIFT_LOCAL_REPOS FLEET_DRIFT_FETCH_CMD FLEET_DRIFT_PROBE_LOG \
          FLEET_DRIFT_TIMEOUT 2>/dev/null || true
}

_seed_repo() {  # path version — working repo with one base commit
    local path="$1" ver="$2"
    mkdir -p "$path"
    (
        cd "$path" || exit 1
        git init -q -b main . >/dev/null 2>&1
        git config user.email t@t
        git config user.name t
        echo "$ver" > .agent-fleet-version
        echo base > base.txt
        git add -A >/dev/null 2>&1
        git commit -qm "base" >/dev/null 2>&1
    )
}

_commit_n() {  # path count prefix
    local path="$1" n="$2" prefix="${3:-c}" i
    for ((i = 1; i <= n; i++)); do
        (
            cd "$path" || exit 1
            echo "$prefix-$i" > "$prefix-$i.txt"
            git add -A >/dev/null 2>&1
            git commit -qm "$prefix $i" >/dev/null 2>&1
        )
    done
}

# Head bare + sub-fleet bare (shared history) + vantage clone carrying remote 'sub'.
# Sets: FX_HEAD_BARE FX_SUB_BARE FX_VANTAGE FX_CONF FX_CACHE
make_fixture() {  # behind ahead [warn] [severe]
    local behind="$1" ahead="$2" warn="${3:-20}" severe="${4:-100}"
    _reset_seams
    FX_HEAD_BARE="$TEST_TMPDIR/head.git"
    FX_SUB_BARE="$TEST_TMPDIR/sub.git"
    FX_VANTAGE="$TEST_TMPDIR/vantage"
    FX_CONF="$TEST_TMPDIR/fleet.conf"
    FX_CACHE="$TEST_TMPDIR/cache/fleet-drift.status"

    git init -q --bare -b main "$FX_HEAD_BARE" >/dev/null 2>&1
    git init -q --bare -b main "$FX_SUB_BARE" >/dev/null 2>&1

    local seed="$TEST_TMPDIR/seed"
    _seed_repo "$seed" "1.2"
    git -C "$seed" remote add origin "$FX_HEAD_BARE" >/dev/null 2>&1
    git -C "$seed" push -q origin main >/dev/null 2>&1

    # Sub-fleet shares the base history, then evolves by $ahead commits
    local subwork="$TEST_TMPDIR/subwork"
    git clone -q "$FX_HEAD_BARE" "$subwork" >/dev/null 2>&1
    git -C "$subwork" config user.email t@t
    git -C "$subwork" config user.name t
    _commit_n "$subwork" "$ahead" sub
    git -C "$subwork" remote add subremote "$FX_SUB_BARE" >/dev/null 2>&1
    git -C "$subwork" push -q subremote main >/dev/null 2>&1

    # Head evolves by $behind commits the sub-fleet lacks
    _commit_n "$seed" "$behind" head
    git -C "$seed" push -q origin main >/dev/null 2>&1

    # Vantage: clone of head, carries the sub remote (mirrors the ~/agent-fleet layout)
    git clone -q "$FX_HEAD_BARE" "$FX_VANTAGE" >/dev/null 2>&1
    git -C "$FX_VANTAGE" config user.email t@t
    git -C "$FX_VANTAGE" config user.name t
    git -C "$FX_VANTAGE" remote add sub "$FX_SUB_BARE" >/dev/null 2>&1

    printf '%s\n' "test-deploy|deployment|$FX_SUB_BARE|main|$FX_VANTAGE:sub|$warn|$severe" > "$FX_CONF"
}

# Sub-fleet bare rebuilt from an UNRELATED root — no merge-base with the head.
make_disconnected_fixture() {
    make_fixture 0 0
    rm -rf "$FX_SUB_BARE"
    git init -q --bare -b main "$FX_SUB_BARE" >/dev/null 2>&1
    local alien="$TEST_TMPDIR/alien"
    _seed_repo "$alien" "1.0"
    _commit_n "$alien" 2 alien
    git -C "$alien" remote add subremote "$FX_SUB_BARE" >/dev/null 2>&1
    git -C "$alien" push -q subremote main >/dev/null 2>&1
}

run_fd() {
    FLEET_DRIFT_CONF="$FX_CONF" \
    FLEET_DRIFT_CACHE="$FX_CACHE" \
    FLEET_DRIFT_HEAD_REPO="$FX_VANTAGE" \
    FLEET_DRIFT_HEAD_REF="origin/main" \
    FLEET_DRIFT_LOCAL_REPOS="${FLEET_DRIFT_LOCAL_REPOS:-}" \
    FLEET_DRIFT_FETCH_CMD="${FLEET_DRIFT_FETCH_CMD:-}" \
    FLEET_DRIFT_TIMEOUT="${FLEET_DRIFT_TIMEOUT:-}" \
    FLEET_DRIFT_PROBE_LOG="${FLEET_DRIFT_PROBE_LOG:-}" \
    SCHED_MARKER_DIR="$TEST_TMPDIR/sched" \
    bash "$FD_SCRIPT" "$@" 2>&1
}

# ── Case 1: conf parsing ─────────────────────────────────────────────────────

test_conf_parsing() {
    make_fixture 0 0
    {
        echo "# comment line"
        echo ""
        echo "test-deploy|deployment|$FX_SUB_BARE|main|$FX_VANTAGE:sub|20|100"
        echo "  # indented comment"
        echo "malformed-row|mirror"
    } > "$FX_CONF"
    local out
    out=$(run_fd --force)
    assert_contains "$out" "CONFIG-ERROR (line 5)" "malformed row must be named by line number" || return 1
    assert_contains "$out" "test-deploy" "good row must still be probed" || return 1
    assert_contains "$out" "IN-SYNC" "good row state must still be reported"
}
run_test "1 conf: comments/blanks skipped, malformed row → CONFIG-ERROR (line N)" test_conf_parsing

# ── Case 2: IN-SYNC ──────────────────────────────────────────────────────────

test_in_sync() {
    make_fixture 0 0
    local out
    out=$(run_fd --force)
    assert_contains "$out" "deployment test-deploy: IN-SYNC" "0/0 with merge-base is IN-SYNC" || return 1
    assert_contains "$out" "FLEET_DRIFT: probed" "healthy state renders without a severity tag" || return 1
    assert_not_contains "$out" "FLEET_DRIFT[" "no severity bracket on a healthy fleet"
}
run_test "2 IN-SYNC" test_in_sync

# ── Case 3: BEHIND within grant ──────────────────────────────────────────────

test_behind_within_grant() {
    make_fixture 3 0
    local out
    out=$(run_fd --force)
    assert_contains "$out" "BEHIND 3" "behind count reported" || return 1
    assert_contains "$out" "within granted drift (warn at 20)" "granted-drift phrasing" || return 1
    assert_not_contains "$out" "FLEET_DRIFT[" "below warn threshold is severity OK"
}
run_test "3 BEHIND 3 — within granted drift, severity OK" test_behind_within_grant

# ── Case 4: SEVERE + the paradigm guard (no auto-reconcile) ─────────────────

test_severe_no_reconcile() {
    make_fixture 12 0 5 10
    local sub_before vant_before
    sub_before=$(git -C "$FX_SUB_BARE" rev-parse main)
    vant_before=$(git -C "$FX_VANTAGE" rev-parse main)
    local out
    out=$(run_fd --force)
    assert_contains "$out" "FLEET_DRIFT[SEVERE]" "behind > severe threshold is SEVERE" || return 1
    assert_contains "$out" "HEAD DECISION REQUIRED" "severe drift demands a head decision" || return 1
    assert_eq "$sub_before" "$(git -C "$FX_SUB_BARE" rev-parse main)" \
        "PARADIGM GUARD: sub-fleet HEAD must be untouched by a SEVERE probe" || return 1
    assert_eq "$vant_before" "$(git -C "$FX_VANTAGE" rev-parse main)" \
        "vantage local branch must be untouched (fetch only, never merge)"
}
run_test "4 behind > severe → SEVERE, HEAD DECISION REQUIRED, sub-fleet HEAD unchanged" test_severe_no_reconcile

# ── Case 5: DIVERGED direction pinned ────────────────────────────────────────

test_diverged_direction() {
    make_fixture 4 2
    local out
    out=$(run_fd --force)
    assert_contains "$out" "DIVERGED 4↓ 2↑" "↓ is behind (head-only commits), ↑ is ahead (installation-only)"
}
run_test "5 DIVERGED — ↓/↑ direction pinned" test_diverged_direction

# ── Case 6: DISCONNECTED refuses behind/ahead counts ─────────────────────────

test_disconnected() {
    make_disconnected_fixture
    local out
    out=$(run_fd --force)
    assert_contains "$out" "DISCONNECTED" "no merge-base is DISCONNECTED" || return 1
    assert_contains "$out" "commits-each-side" "symmetric figure labelled commits-each-side" || return 1
    assert_contains "$out" "FLEET_DRIFT[SEVERE]" "DISCONNECTED is unconditionally SEVERE" || return 1
    assert_not_contains "$out" "BEHIND" "MUST NOT print a BEHIND count over unrelated histories" || return 1
    assert_not_contains "$out" "AHEAD" "MUST NOT print an AHEAD count over unrelated histories"
}
run_test "6 DISCONNECTED — no BEHIND/AHEAD tokens, commits-each-side present" test_disconnected

# ── Case 7: UNREACHABLE — reason named, last-known retained, wall-clock bounded ──

test_unreachable() {
    make_fixture 0 0
    run_fd --force >/dev/null            # seeds the last-known state in the cache
    rm -rf "$FX_SUB_BARE"                # remote vanishes
    local out
    out=$(run_fd --force)
    assert_contains "$out" "UNREACHABLE" "state named" || return 1
    assert_contains "$out" "last known" "last-known state retained" || return 1
    assert_contains "$out" "IN-SYNC" "the retained state carries its content" || return 1

    # Hanging fetch is killed by the per-remote timeout — bounded, exit 0.
    printf '#!/usr/bin/env bash\nsleep 60\n' > "$TEST_TMPDIR/hang.sh"
    chmod +x "$TEST_TMPDIR/hang.sh"
    local t0=$SECONDS rc=0
    out=$(FLEET_DRIFT_FETCH_CMD="$TEST_TMPDIR/hang.sh" FLEET_DRIFT_TIMEOUT=1 run_fd --force) || rc=$?
    local dt=$((SECONDS - t0))
    _reset_seams
    [ "$rc" -eq 0 ] || { echo "    probe must exit 0 on unreachable remotes (got $rc)"; return 1; }
    [ "$dt" -lt 10 ] || { echo "    hung fetch not bounded: took ${dt}s"; return 1; }
    assert_contains "$out" "UNREACHABLE" "timed-out fetch reports UNREACHABLE"
}
run_test "7 UNREACHABLE — reason + last-known retained, exit 0, wall-clock bounded" test_unreachable

# ── Case 8: STALE-PROBE — a fresh-looking count with a stale date is not health ──

test_stale_probe() {
    make_fixture 0 0
    mkdir -p "$(dirname "$FX_CACHE")"
    local old_epoch=$(( $(date +%s) - 29 * 86400 ))
    cat > "$FX_CACHE" << EOF
probe_epoch=$old_epoch
probe_date=$(date -d "@$old_epoch" +%Y-%m-%d)
severity=OK
body=head vantage abc1234 v1.2 | deployment test-deploy: IN-SYNC, last activity 0d | local checkouts fresh (all fetched <24h)
EOF
    local out
    out=$(run_fd --status)
    assert_contains "$out" "29d" "the probe age must be named" || return 1
    assert_contains "$out" "FLEET_DRIFT[" "29d-old counts must escalate to at least WARN" || return 1
    assert_not_contains "$out" "FLEET_DRIFT: probed" "a green count with a stale date must never render as health"
}
run_test "8 STALE-PROBE — 29d-old 0/0 cache escalates, never renders as health" test_stale_probe

# ── Case 9: stale local fetch — the 29-day / '0 behind' regression guard ─────

test_stale_local_fetch() {
    make_fixture 0 0
    local co="$TEST_TMPDIR/checkout"
    git clone -q "$FX_HEAD_BARE" "$co" >/dev/null 2>&1
    git -C "$co" fetch -q origin main >/dev/null 2>&1   # creates FETCH_HEAD
    touch -d '29 days ago' "$co/.git/FETCH_HEAD"
    local out
    out=$(FLEET_DRIFT_LOCAL_REPOS="$co" run_fd --local-only)
    _reset_seams
    assert_contains "$out" "29d" "the fetch age must be named" || return 1
    assert_contains "$out" "fetch origin" "remediation command named" || return 1
    assert_not_contains "$out" "IN-SYNC" "0-behind against a 29d-old origin means nothing" || return 1
    assert_not_contains "$out" "fresh" "must not claim freshness with a stale fetch"
}
run_test "9 stale local fetch — 0-behind against 29d-old origin names the age, no 'fresh'" test_stale_local_fetch

# ── Case 10: date gate — second same-day --if-due makes zero network calls ───

test_date_gate() {
    make_fixture 1 0
    export FLEET_DRIFT_PROBE_LOG="$TEST_TMPDIR/probes.log"
    local out1 out2 n1 n2 n3
    out1=$(run_fd --if-due)
    assert_contains "$out1" "FLEET_DRIFT" "first --if-due of the day probes and reports" || return 1
    n1=$(wc -l < "$FLEET_DRIFT_PROBE_LOG" | tr -d ' ')
    [ "$n1" -gt 0 ] || { echo "    first run made no probes"; return 1; }
    out2=$(run_fd --if-due)
    n2=$(wc -l < "$FLEET_DRIFT_PROBE_LOG" | tr -d ' ')
    assert_eq "$n1" "$n2" "second same-day --if-due must make ZERO network calls" || return 1
    assert_contains "$out2" "FLEET_DRIFT" "gated run still reports from cache — silence never occurs" || return 1
    run_fd --force >/dev/null
    n3=$(wc -l < "$FLEET_DRIFT_PROBE_LOG" | tr -d ' ')
    _reset_seams
    [ "$n3" -gt "$n2" ] || { echo "    --force did not bypass the date gate"; return 1; }
}
run_test "10 date gate — gated --if-due is network-silent but never output-silent; --force bypasses" test_date_gate

# ── Case 11: no-vantage degrade ──────────────────────────────────────────────

test_no_vantage_degrade() {
    make_fixture 3 0
    printf '%s\n' "test-deploy|deployment|$FX_SUB_BARE|main|-|20|100" > "$FX_CONF"
    local out
    out=$(run_fd --force)
    assert_contains "$out" "counts unavailable on this machine" "degrade must say so" || return 1
    assert_not_contains "$out" "BEHIND" "never a fabricated count without a vantage"
}
run_test "11 no vantage — ls-remote degrade says 'counts unavailable on this machine'" test_no_vantage_degrade

# ── Case 12: empty conf and missing conf are distinct from silence ───────────

test_empty_and_missing_conf() {
    make_fixture 0 0
    printf '# no installations registered yet\n' > "$FX_CONF"
    local out
    out=$(run_fd --force)
    assert_contains "$out" "FLEET_DRIFT: no sub-fleets registered" "empty conf is an explicit statement" || return 1
    rm -f "$FX_CONF"
    out=$(run_fd --force)
    assert_contains "$out" "CONFIG-ERROR" "missing conf in the personal repo is a config error" || return 1
    [ -n "$out" ] || { echo "    missing conf must never be silent"; return 1; }
}
run_test "12 empty conf → 'no sub-fleets registered'; missing conf → CONFIG-ERROR" test_empty_and_missing_conf

# ── Case 13: hook-check contract ─────────────────────────────────────────────

# Fixture cfg repo whose fleet-drift.sh is a stub echoing a canned line.
make_check_fixture() {  # canned-line ('' = no stub output)
    local canned="$1"
    CK_REPO="$TEST_TMPDIR/cfg"
    mkdir -p "$CK_REPO/setup/scripts"
    cat > "$CK_REPO/setup/scripts/fleet-drift.sh" << STUB
#!/usr/bin/env bash
touch "$TEST_TMPDIR/stub-invoked"
[ -n '$canned' ] && printf '%s\n' '$canned'
exit 0
STUB
}

run_check() {  # project-dir config-repo
    (
        PROJECT_DIR="$1"
        CONFIG_REPO="$2"
        WARNINGS=""
        INBOX_MSG=""
        source "$FD_CHECK" 2>/dev/null || true
        printf 'W::%s::EW\nI::%s::EI\n' "$WARNINGS" "$INBOX_MSG"
    )
}

test_check_routing() {
    make_check_fixture "FLEET_DRIFT: probed 2026-09-17 | head agent-fleet abc1234 v1.2 | mirror m1: IN-SYNC"
    local out
    out=$(run_check "$CK_REPO" "$CK_REPO")
    assert_contains "$out" "I::FLEET_DRIFT: probed" "OK line routes to INBOX_MSG" || return 1
    assert_contains "$out" "W::::EW" "OK line leaves WARNINGS empty" || return 1

    make_check_fixture "FLEET_DRIFT[SEVERE]: deployment d1: DISCONNECTED — no common ancestor"
    out=$(run_check "$CK_REPO" "$CK_REPO")
    assert_contains "$out" "W::FLEET_DRIFT[SEVERE]" "degraded line routes to WARNINGS" || return 1
    assert_contains "$out" "I::::EI" "degraded line leaves INBOX_MSG empty" || return 1
    return 0
}
run_test "13a check: OK → INBOX_MSG, degraded → WARNINGS" test_check_routing

test_check_non_cfg_project() {
    make_check_fixture "FLEET_DRIFT: probed today | all healthy"
    mkdir -p "$TEST_TMPDIR/other-project"
    local out
    out=$(run_check "$TEST_TMPDIR/other-project" "$CK_REPO")
    assert_contains "$out" "W::::EW" "non-cfg project leaves WARNINGS untouched" || return 1
    assert_contains "$out" "I::::EI" "non-cfg project leaves INBOX_MSG untouched" || return 1
    assert_file_not_exists "$TEST_TMPDIR/stub-invoked" "non-cfg project must not even invoke the probe"
}
run_test "13b check: non-cfg project returns immediately, probe never invoked" test_check_non_cfg_project

test_check_degradation_reported() {
    # Missing probe script → reported degradation, not silence
    CK_REPO="$TEST_TMPDIR/cfg-noscript"
    mkdir -p "$CK_REPO"
    local out
    out=$(run_check "$CK_REPO" "$CK_REPO")
    assert_contains "$out" "W::FLEET_DRIFT" "missing probe script is a reported degradation" || return 1

    # Probe that produces no output → reported degradation
    make_check_fixture ""
    out=$(run_check "$CK_REPO" "$CK_REPO")
    assert_contains "$out" "W::FLEET_DRIFT" "empty probe output is a reported degradation"
}
run_test "13c check: missing/silent probe is a reported degradation, never silence" test_check_degradation_reported

test_check_syntax_and_budget() {
    bash -n "$FD_CHECK" || { echo "    bash -n failed on $FD_CHECK"; return 1; }
    local lines
    lines=$(wc -l < "$FD_CHECK" | tr -d ' ')
    [ "$lines" -lt 100 ] || { echo "    check is $lines lines — hook checks must stay under 100"; return 1; }
    bash -n "$FD_SCRIPT" || { echo "    bash -n failed on $FD_SCRIPT"; return 1; }
}
run_test "13d check: bash -n passes, file under 100 lines" test_check_syntax_and_budget

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
