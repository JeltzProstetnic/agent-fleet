#!/usr/bin/env bash
# Tests for CFG-143 + AFT-71: fleet version check module (17-fleet-updates.sh)
# Verifies: newer upstream → warning, same version → silent, missing version → skip,
#           no upstream/origin remote → skip, corporate context detection, date gating,
#           origin fallback, bounded daily fetch, minor-channel default, CHANGELOG headline.
# Remotes are local bare repos or fixtures that fail/hang locally — no network.

source "$(dirname "$0")/test-helpers.sh"

suite_header "Fleet Version Check (CFG-143)"

CHECK_17="$REPO_ROOT/global/hooks/checks/17-fleet-updates.sh"

# ── Helper: set up minimal env for the check module ──────────────────────────

setup_check_env() {
    export CONFIG_REPO="$TEST_TMPDIR/config-repo"
    export PROJECT_DIR="$TEST_TMPDIR/project"
    WARNINGS=""
    INBOX_MSG=""

    mkdir -p "$CONFIG_REPO/.git"
    mkdir -p "$PROJECT_DIR"

    # Clear any date-gate marker from previous test. The gate follows
    # ${SCHED_MARKER_DIR:-${TMPDIR:-/tmp}} (GH#13) — pin it inside the sandbox
    # so this clears the marker the check reads, whatever TMPDIR is.
    export SCHED_MARKER_DIR="$TEST_TMPDIR/sched"
    mkdir -p "$SCHED_MARKER_DIR"
    rm -f "$SCHED_MARKER_DIR"/.fleet-update-check-* 2>/dev/null || true
}

# Create a project git repo with an upstream remote pointing to a bare repo.
# Writes .agent-fleet-version into both local and upstream.
# Usage: create_upstream_env <local_version> <upstream_version> [remote_name=upstream]
create_upstream_env() {
    local local_ver="${1:-0.2}"
    local upstream_ver="${2:-0.3}"
    local remote="${3:-upstream}"

    local bare="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"

    # Build template repo with upstream version
    create_git_repo "$template"
    echo "$upstream_ver" > "$template/.agent-fleet-version"
    git -C "$template" add -A
    git -C "$template" commit -m "upstream v$upstream_ver" >/dev/null 2>&1

    # Push to bare
    create_bare_repo "$bare"
    git -C "$template" remote add origin "$bare"
    git -C "$template" push origin main >/dev/null 2>&1

    # Set up project dir as a git repo with upstream remote
    create_git_repo "$PROJECT_DIR"
    echo "$local_ver" > "$PROJECT_DIR/.agent-fleet-version"
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -m "local v$local_ver" >/dev/null 2>&1
    git -C "$PROJECT_DIR" remote add "$remote" "$bare"
    git -C "$PROJECT_DIR" fetch "$remote" >/dev/null 2>&1
}

# Publish a new upstream release to the bare repo WITHOUT refreshing the project's
# remote-tracking ref, so the project's cache is stale until something fetches.
# Usage: publish_upstream <version> [CHANGELOG.md content]
publish_upstream() {
    local ver="$1" template="$TEST_TMPDIR/template"
    echo "$ver" > "$template/.agent-fleet-version"
    if [ $# -ge 2 ]; then printf '%s\n' "$2" > "$template/CHANGELOG.md"; fi
    git -C "$template" add -A
    git -C "$template" commit -m "upstream v$ver" >/dev/null 2>&1
    git -C "$template" push origin main >/dev/null 2>&1
}

# The exact message the check emits, without a CHANGELOG suffix.
base_msg() {
    echo "FLEET_UPDATE: v$1 → v$2 available ($3 channel). Run 'upgrade.sh --check' to preview."
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 1: Core version detection
# ══════════════════════════════════════════════════════════════════════════════

test_newer_upstream_warns() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    # Channel 'all': the minor bump is detected regardless of the default channel
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "FLEET_UPDATE" \
        "newer upstream should produce FLEET_UPDATE warning"
    assert_contains "$WARNINGS" "0.2" "warning should mention local version"
    assert_contains "$WARNINGS" "0.3" "warning should mention upstream version"
    assert_contains "$WARNINGS" "upgrade.sh" "warning should mention upgrade command"
}
run_test "newer upstream version produces FLEET_UPDATE warning" test_newer_upstream_warns

test_same_version_silent() {
    setup_check_env
    create_upstream_env "0.2" "0.2"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "same version should not produce FLEET_UPDATE warning"
}
run_test "same version produces no warning" test_same_version_silent

test_older_upstream_silent() {
    setup_check_env
    create_upstream_env "0.3" "0.2"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "older upstream should not produce FLEET_UPDATE warning"
}
run_test "older upstream version produces no warning" test_older_upstream_silent

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 2: Graceful degradation
# ══════════════════════════════════════════════════════════════════════════════

test_missing_version_file_skips() {
    setup_check_env
    # PROJECT_DIR exists but has no .agent-fleet-version and no git
    mkdir -p "$PROJECT_DIR"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "missing .agent-fleet-version should skip gracefully"
}
run_test "missing .agent-fleet-version skips gracefully" test_missing_version_file_skips

test_no_upstream_remote_skips() {
    setup_check_env
    create_git_repo "$PROJECT_DIR"
    echo "0.2" > "$PROJECT_DIR/.agent-fleet-version"
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -m "v0.2" >/dev/null 2>&1
    # No remote at all — neither upstream nor the origin fallback (AFT-71)
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "no upstream remote should skip gracefully"
}
run_test "no upstream or origin remote skips gracefully" test_no_upstream_remote_skips

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 3: Corporate context detection
# ══════════════════════════════════════════════════════════════════════════════

test_corporate_origin_still_warns() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    # Override origin to a corporate-org URL — still triggers version check
    git -C "$PROJECT_DIR" remote add origin "https://github.com/example-org/agent-fleet.git" 2>/dev/null || \
        git -C "$PROJECT_DIR" remote set-url origin "https://github.com/example-org/agent-fleet.git"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "FLEET_UPDATE" \
        "corporate origin should still produce FLEET_UPDATE warning"
}
run_test "corporate origin still triggers update warning" test_corporate_origin_still_warns

test_non_corporate_no_corporate_label() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    # Origin points to personal repo (default from create_upstream_env has no origin)
    git -C "$PROJECT_DIR" remote add origin "https://github.com/example-user/my-fleet.git" 2>/dev/null || true
    source "$CHECK_17"
    assert_contains "$WARNINGS" "FLEET_UPDATE" "should still warn"
    assert_not_contains "$WARNINGS" "corporate" \
        "non-corporate origin should not mention corporate"
}
run_test "non-corporate origin omits corporate label" test_non_corporate_no_corporate_label

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 4: Date gating
# ══════════════════════════════════════════════════════════════════════════════

test_date_gate_prevents_rerun() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"

    # First run should produce warning
    source "$CHECK_17"
    assert_contains "$WARNINGS" "FLEET_UPDATE" "first run should warn"

    # Reset WARNINGS and run again — date gate should prevent it
    WARNINGS=""
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "second run same day should be gated"
}
run_test "date gate prevents redundant checks" test_date_gate_prevents_rerun

test_daily_gate_is_per_project() {
    setup_check_env
    create_upstream_env "0.2" "0.2"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" "project A has no update"

    # A second project the same day must not be gated by project A's run
    local proj_b="$TEST_TMPDIR/project-b"
    create_git_repo "$proj_b"
    echo "0.1" > "$proj_b/.agent-fleet-version"
    echo "all" > "$proj_b/.agent-fleet-channel"
    git -C "$proj_b" remote add upstream "$TEST_TMPDIR/upstream.git"
    git -C "$proj_b" fetch upstream >/dev/null 2>&1
    PROJECT_DIR="$proj_b"
    WARNINGS=""
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v0.1 → v0.2" \
        "another project is still checked after project A consumed its own gate"
}
run_test "daily gate is per project" test_daily_gate_is_per_project

test_sched_gate_consumed_without_update() {
    setup_check_env
    # Production path: CONFIG_REPO carries sched-lib (fixture copy inside the sandbox)
    mkdir -p "$CONFIG_REPO/setup/scripts"
    cp "$REPO_ROOT/setup/scripts/sched-lib.sh" "$CONFIG_REPO/setup/scripts/"
    create_upstream_env "0.2" "0.2"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" "first run: no update"

    publish_upstream "0.3"
    git -C "$PROJECT_DIR" fetch upstream >/dev/null 2>&1
    WARNINGS=""
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" \
        "a run without an update still consumes the day's sched-lib gate (one fetch per day)"
}
run_test "sched-lib gate is consumed by a run without an update" test_sched_gate_consumed_without_update

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 5: Remote selection (AFT-71)
# ══════════════════════════════════════════════════════════════════════════════

test_origin_only_remote_warns() {
    setup_check_env
    # A user who cloned the template directly has only `origin`
    create_upstream_env "0.2" "0.3" "origin"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v0.2 → v0.3" "origin is the fallback when there is no upstream"
}
run_test "origin-only clone is checked against origin" test_origin_only_remote_warns

test_upstream_preferred_over_origin() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    local other="$TEST_TMPDIR/other"
    create_git_repo "$other"
    echo "0.9" > "$other/.agent-fleet-version"
    git -C "$other" add -A
    git -C "$other" commit -m "v0.9" >/dev/null 2>&1
    create_bare_repo "$TEST_TMPDIR/other.git"
    git -C "$other" remote add origin "$TEST_TMPDIR/other.git"
    git -C "$other" push origin main >/dev/null 2>&1
    git -C "$PROJECT_DIR" remote add origin "$TEST_TMPDIR/other.git"
    git -C "$PROJECT_DIR" fetch origin >/dev/null 2>&1
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v0.2 → v0.3" "upstream wins when both remotes exist"
    assert_not_contains "$WARNINGS" "0.9" "origin is only the fallback"
}
run_test "upstream is preferred over origin" test_upstream_preferred_over_origin

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 6: Bounded fetch (AFT-71)
# ══════════════════════════════════════════════════════════════════════════════

test_fetch_sees_new_release() {
    setup_check_env
    create_upstream_env "0.2" "0.2"
    publish_upstream "0.3"    # project's upstream/main still says 0.2
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v0.2 → v0.3" "the daily fetch refreshes a stale remote-tracking ref"
}
run_test "daily fetch picks up a release the cached ref has not seen" test_fetch_sees_new_release

test_unreachable_remote_silent_and_fast() {
    setup_check_env
    create_upstream_env "0.2" "0.3"   # cached ref already says 0.3
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    git -C "$PROJECT_DIR" remote set-url upstream "$TEST_TMPDIR/does-not-exist.git"
    local rc=0 start=$SECONDS elapsed
    source "$CHECK_17" || rc=$?
    elapsed=$(( SECONDS - start ))
    assert_eq "0" "$rc" "a failed fetch must not fail the check"
    assert_eq "1" "$(( elapsed <= 6 ))" "check finished in ${elapsed}s (limit 6s)"
    assert_contains "$WARNINGS" "v0.2 → v0.3" "a failed fetch falls back to the cached ref"
}
run_test "unreachable remote: silent, fast, cached ref used" test_unreachable_remote_silent_and_fast

test_hanging_remote_bounded() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    # A remote that never answers: an ssh transport that just sleeps (no network)
    printf '#!/bin/sh\nexec sleep 30\n' > "$TEST_TMPDIR/hang-ssh"
    chmod +x "$TEST_TMPDIR/hang-ssh"
    local GIT_SSH_COMMAND="$TEST_TMPDIR/hang-ssh"
    export GIT_SSH_COMMAND
    git -C "$PROJECT_DIR" remote set-url upstream "fixture-host:fleet.git"
    local rc=0 start=$SECONDS elapsed
    source "$CHECK_17" || rc=$?
    elapsed=$(( SECONDS - start ))
    assert_eq "0" "$rc" "a hanging fetch must not fail the check"
    assert_eq "1" "$(( elapsed <= 6 ))" "check finished in ${elapsed}s (limit 6s)"
    assert_contains "$WARNINGS" "v0.2 → v0.3" "a timed-out fetch falls back to the cached ref"
}
run_test "hanging remote: fetch is cut off within ~6s" test_hanging_remote_bounded

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 7: Update channels (AFT-71: default is `minor`)
# ══════════════════════════════════════════════════════════════════════════════

test_default_channel_minor_bump_warns() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v0.2 → v0.3" "default channel notifies a minor bump"
    assert_contains "$WARNINGS" "(minor channel)" "default channel is minor"
}
run_test "default channel (minor) notifies a minor bump" test_default_channel_minor_bump_warns

test_default_channel_major_bump_warns() {
    setup_check_env
    create_upstream_env "1.2" "2.1"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v1.2 → v2.1" "default channel notifies a major bump even if not x.0.0"
}
run_test "default channel (minor) notifies a major bump" test_default_channel_major_bump_warns

test_default_channel_patch_only_silent() {
    setup_check_env
    create_upstream_env "1.2.0" "1.2.1"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" "default channel skips a patch-only bump"
}
run_test "default channel (minor) skips a patch-only bump" test_default_channel_patch_only_silent

test_major_channel_skips_minor() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "major" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" "major channel skips a minor release"
}
run_test "major channel skips a minor release" test_major_channel_skips_minor

test_major_channel_x00_warns() {
    setup_check_env
    create_upstream_env "1.4" "2.0.0"
    echo "major" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v1.4 → v2.0.0 available (major channel)" "major channel notifies x.0.0"
}
run_test "major channel notifies an x.0.0 release" test_major_channel_x00_warns

test_all_channel_patch_warns() {
    setup_check_env
    create_upstream_env "1.2.0" "1.2.1"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v1.2.0 → v1.2.1 available (all channel)" "all channel notifies a patch"
}
run_test "all channel notifies a patch-only bump" test_all_channel_patch_warns

test_unknown_channel_falls_back_to_minor() {
    setup_check_env
    create_upstream_env "1.2.0" "1.2.1"
    echo "nightly" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_not_contains "$WARNINGS" "FLEET_UPDATE" "an unknown channel value behaves as minor"
}
run_test "unknown channel value falls back to minor" test_unknown_channel_falls_back_to_minor

test_rolling_channel_acts_as_all() {
    setup_check_env
    create_upstream_env "1.2.0" "1.2.1"
    # `upgrade.sh --channel rolling` writes this value; it notified every release before AFT-71
    echo "rolling" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_contains "$WARNINGS" "v1.2.0 → v1.2.1 available (rolling channel)" \
        "rolling (upgrade.sh's value) still notifies every newer version"
}
run_test "rolling channel (from upgrade.sh) behaves as all" test_rolling_channel_acts_as_all

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 8: What's new — CHANGELOG headline (AFT-71)
# ══════════════════════════════════════════════════════════════════════════════

# Publish upstream 0.3 with the given CHANGELOG and refresh the cache explicitly,
# so these tests depend on the CHANGELOG logic only, not on the check's fetch.
changelog_env() {
    setup_check_env
    create_upstream_env "0.2" "0.2"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    publish_upstream "0.3" "$1"
    git -C "$PROJECT_DIR" fetch upstream >/dev/null 2>&1
}

test_changelog_headline_appended() {
    changelog_env "# Changelog

## [Unreleased]

Unreleased work that must not be quoted.

## [0.3] — 2026-11-18

**Update notices.** Sessions now hear about new releases.

### Added
- something"
    source "$CHECK_17"
    assert_eq "$(base_msg 0.2 0.3 all) — Update notices. Sessions now hear about new releases." \
        "$WARNINGS" "headline of the matching section is appended, bold stripped"
}
run_test "CHANGELOG headline of the release is appended" test_changelog_headline_appended

test_changelog_skips_subheadings() {
    changelog_env "## [0.3]

### Added

- First item"
    source "$CHECK_17"
    assert_eq "$(base_msg 0.2 0.3 all) — - First item" "$WARNINGS" \
        "first non-empty, non-heading line of the section"
}
run_test "CHANGELOG suffix skips sub-headings" test_changelog_skips_subheadings

test_changelog_truncated_120() {
    local long
    printf -v long '%*s' 200 ''
    long=${long// /y}
    changelog_env "## [0.3]

$long"
    source "$CHECK_17"
    local suffix="${WARNINGS#*to preview. — }"
    assert_eq "120" "${#suffix}" "suffix is truncated to 120 chars"
}
run_test "CHANGELOG suffix is truncated to 120 chars" test_changelog_truncated_120

test_no_changelog_no_suffix() {
    setup_check_env
    create_upstream_env "0.2" "0.3"
    echo "all" > "$PROJECT_DIR/.agent-fleet-channel"
    source "$CHECK_17"
    assert_eq "$(base_msg 0.2 0.3 all)" "$WARNINGS" "no CHANGELOG → no suffix"
}
run_test "no CHANGELOG: no suffix" test_no_changelog_no_suffix

test_changelog_without_section_no_suffix() {
    changelog_env "## [Unreleased]

Not released yet.

## [0.2] — 2026-01-01

Older release text."
    source "$CHECK_17"
    assert_eq "$(base_msg 0.2 0.3 all)" "$WARNINGS" "no section for the upstream version → no suffix"
}
run_test "CHANGELOG without a matching section: no suffix" test_changelog_without_section_no_suffix

# ══════════════════════════════════════════════════════════════════════════════

suite_summary
