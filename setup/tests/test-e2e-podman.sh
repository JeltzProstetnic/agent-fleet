#!/usr/bin/env bash
# Tests for setup/scripts/e2e-podman.sh
#
# WHY (CFG-675, option (a), 2026-09-28): the runner always cloned the PUBLISHED
# template from GitHub, so no uncommitted edit could ever be under test — yet a
# green run stamped the marker the Tier 2 gate reads as proof. `--source <dir>`
# ships a local working tree (uncommitted edits included) into the container
# instead, and the marker records WHAT was tested.
#
# podman is faked: every call is logged, `cp` of a tarball is captured, so the
# tests never start a container or touch the network.
source "$(dirname "$0")/test-helpers.sh"

suite_header "e2e-podman.sh: --source runs a local working tree"

SCRIPT="$REPO_ROOT/setup/scripts/e2e-podman.sh"

# Fake podman on PATH. Logs "$*" per call; copies any local .tar it is asked to
# `cp` into $FAKE_CAPTURE so the test can inspect what would enter the container.
make_fake_podman() {
    local bin="$TEST_TMPDIR/bin-$RANDOM"; mkdir -p "$bin"
    cat > "$bin/podman" << 'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [ "$1" = cp ] && [ -f "$2" ] && [[ "$2" == *.tar ]]; then
    cp "$2" "$FAKE_CAPTURE/"
fi
exit 0
FAKE
    chmod +x "$bin/podman"
    printf '%s' "$bin"
}

# A git working tree with one committed file, then an UNCOMMITTED edit to it,
# one untracked file, and one ignored file.
make_source_tree() {
    local d="$TEST_TMPDIR/src-$RANDOM"; mkdir -p "$d"
    (
        cd "$d" || exit 1
        git init -q
        git config user.email t@t; git config user.name t
        printf '#!/usr/bin/env bash\necho setup\n' > setup.sh
        printf 'committed\n' > payload.txt
        printf 'ignored.txt\n' > .gitignore
        git add -A; git commit -qm init
        printf 'UNCOMMITTED-EDIT\n' > payload.txt
        printf 'new\n' > untracked.txt
        printf 'secret\n' > ignored.txt
    )
    printf '%s' "$d"
}

run_runner() {
    local bin="$1"; shift
    FAKE_LOG="$TEST_TMPDIR/podman.log" FAKE_CAPTURE="$TEST_TMPDIR/capture" \
    ANTILOCKOUT_E2E_MARKER="$TEST_TMPDIR/marker" \
    PATH="$bin:$PATH" bash "$SCRIPT" "$@" > "$TEST_TMPDIR/out.txt" 2>&1
}

reset_state() {
    rm -rf "$TEST_TMPDIR/podman.log" "$TEST_TMPDIR/capture" "$TEST_TMPDIR/marker"
    mkdir -p "$TEST_TMPDIR/capture"
}

test_default_still_clones_the_published_template() {
    reset_state
    local bin; bin=$(make_fake_podman)
    run_runner "$bin"
    local cloned="no"; grep -q "git clone" "$TEST_TMPDIR/podman.log" && cloned="yes"
    assert_eq "yes" "$cloned" "without --source the published template is cloned, as before"
}
run_test "default: unchanged, clones from GitHub" test_default_still_clones_the_published_template

test_source_does_not_clone() {
    reset_state
    local bin; bin=$(make_fake_podman); local src; src=$(make_source_tree)
    run_runner "$bin" --source "$src"
    local cloned="no"; grep -q "git clone" "$TEST_TMPDIR/podman.log" && cloned="yes"
    assert_eq "no" "$cloned" "--source must not clone GitHub"
}
run_test "--source: no git clone" test_source_does_not_clone

test_source_ships_uncommitted_edits() {
    reset_state
    local bin; bin=$(make_fake_podman); local src; src=$(make_source_tree)
    run_runner "$bin" --source "$src"
    local tarball; tarball=$(ls "$TEST_TMPDIR"/capture/*.tar 2>/dev/null | head -1)
    local x="$TEST_TMPDIR/extract-$RANDOM"; mkdir -p "$x"
    [ -n "$tarball" ] && tar -C "$x" -xf "$tarball"
    assert_eq "UNCOMMITTED-EDIT" "$(cat "$x/payload.txt" 2>/dev/null)" "the working-tree content is what enters the container"
    assert_eq "new" "$(cat "$x/untracked.txt" 2>/dev/null)" "untracked, non-ignored files travel too"
    local ign="absent"; [ -e "$x/ignored.txt" ] && ign="present"
    assert_eq "absent" "$ign" "gitignored files stay out"
    local g="absent"; [ -d "$x/.git" ] && g="present"
    assert_eq "present" "$g" ".git travels so setup.sh sees a repository"
}
run_test "--source: ships the working tree, uncommitted edits included, ignored files excluded" test_source_ships_uncommitted_edits

test_source_missing_dir_fails_before_podman() {
    reset_state
    local bin; bin=$(make_fake_podman)
    local rc=0; run_runner "$bin" --source "$TEST_TMPDIR/does-not-exist" || rc=$?
    local created="no"; grep -q "^create" "$TEST_TMPDIR/podman.log" 2>/dev/null && created="yes"
    assert_eq "no" "$created" "a bad --source must fail before any container is created"
    local failed="no"; [ "$rc" -ne 0 ] && failed="yes"
    assert_eq "yes" "$failed" "a bad --source exits non-zero (rc=$rc)"
}
run_test "--source: missing directory fails fast" test_source_missing_dir_fails_before_podman

test_marker_records_what_was_tested() {
    reset_state
    local bin; bin=$(make_fake_podman); local src; src=$(make_source_tree)
    run_runner "$bin" --source "$src"
    local m; m=$(cat "$TEST_TMPDIR/marker" 2>/dev/null)
    assert_contains "$m" "source=$src" "the marker names the tree that was tested"
    assert_contains "$m" "dirty=yes" "the marker says uncommitted edits were included"
}
run_test "marker records source and dirty state" test_marker_records_what_was_tested

suite_summary
