#!/usr/bin/env bash
# Tests for afleet.sh session-lock prompt and worktree flow.
# Covers CFG bug: second afleet launch on locked project was launching CC anyway
# after user declined the prompt. New flow: worktree-or-quit, no steal.
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/afleet.sh"

suite_header "afleet.sh: session-lock prompt + worktree mode"

# ── Shared fixture ────────────────────────────────────────────────────────────
# Builds a CONFIG_REPO sandbox with registry, session-lock.sh library,
# git-sync-check stub, and a mock mclaude that records invocation.

build_env() {
    local env="$TEST_TMPDIR/env"
    local home="$TEST_TMPDIR/home"
    mkdir -p "$env/setup/scripts" "$env/cross-project" "$home/.local/bin"

    cat > "$env/registry.md" << 'EOF'
# Project Registry

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| alpha | P1 | — | `~/alpha` | `t/alpha` | m1 | code | active | |
EOF

    cat > "$env/cross-project/dashboard-cache.md" << 'EOF'
# Dashboard Cache

| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
| alpha | P1 | — | ~/alpha | code | 1 open | 1M |  |  |  |
EOF

    # Copy the real session-lock.sh so the library being tested is the actual one.
    cp "$REPO_ROOT/setup/scripts/session-lock.sh" "$env/setup/scripts/session-lock.sh"

    # Stub git-sync-check.sh so pre_launch_sync doesn't try to hit the network
    cat > "$env/setup/scripts/git-sync-check.sh" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$env/setup/scripts/git-sync-check.sh"

    # Stub sync.sh (deploy is a no-op in tests)
    cat > "$env/sync.sh" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$env/sync.sh"

    # Mock mclaude — writes a marker so we can assert whether CC was launched
    cat > "$home/.local/bin/mclaude" << MOCK
#!/usr/bin/env bash
echo "MOCK_MCLAUDE_CALLED cwd=\$(pwd)" >> "$TEST_TMPDIR/mclaude.log"
MOCK
    chmod +x "$home/.local/bin/mclaude"

    echo "$env|$home"
}

# Initialize a target project as a real git repo so `git worktree` works
init_project() {
    local dir="$1"
    mkdir -p "$dir/.claude"
    touch "$dir/CLAUDE.md"
    git -C "$dir" init -q -b main
    git -C "$dir" add -A
    git -C "$dir" -c user.name=test -c user.email=t@t commit -q -m "init"
}

# Create a lock file pointing at a live PID (a local sleep we start + trap clean)
write_live_lock() {
    local project_dir="$1"
    local pid="$2"
    local host
    host=$(cat /etc/hostname 2>/dev/null || hostname)
    cat > "$project_dir/.claude/.session-lock" <<JSON
{"machine":"$host","pid":$pid,"user":"test","sessionId":"other-sess-$pid","timestamp":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"}
JSON
}

# Run a shell function under a wall-clock bound (CFG-474). `timeout` cannot wrap
# a function, and post_session_cleanup calls exit, so it needs a subshell anyway.
# The bound is the point: a prompt that blocks must FAIL this suite, never hang
# it — the original defect cost 128 tests with no summary and no exit code.
run_bounded() {
    local secs="$1"; shift
    ( "$@" >/dev/null 2>&1 ) &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do
        sleep 1; waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        printf "${RED}    BLOCKED: call did not return within ${secs}s${RESET}\n" >&2
        return 124
    fi
    wait "$pid" 2>/dev/null || true
    return 0
}

# ── Case 1: no lock → mclaude is launched ─────────────────────────────────────

test_no_lock_launches_mclaude() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" AFLEET_DRY_RUN=1 \
        bash "$SCRIPT" alpha </dev/null >/dev/null 2>&1 || true

    # DRY_RUN prints the "would cd" line so mclaude.log won't appear — look at stdout instead.
    local out
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" AFLEET_DRY_RUN=1 \
        bash "$SCRIPT" alpha </dev/null 2>&1)
    assert_contains "$out" "DRY_RUN: would cd to $project" "no-lock path must reach launch" || return 1
}
run_test "no lock → launches normally" test_no_lock_launches_mclaude

# ── Case 2: live lock + 'q' → no launch, exit 0 ───────────────────────────────

test_live_lock_q_aborts() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    # CFG-670: feed through the prompt's own seam, not stdin. The real read
    # targets /dev/tty, which wins over a pipe wherever a controlling terminal
    # exists — so a piped answer is silently ignored and this blocks forever
    # under tmux, while passing under a Claude Code Bash call, which has no tty.
    printf 'q\n' > "$TEST_TMPDIR/answer-q-abort"
    local out rc=0
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-q-abort" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha </dev/null 2>&1) || rc=$?

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    assert_eq "0" "$rc" "quit path should exit 0 (clean no-op)" || return 1
    assert_not_contains "$out" "DRY_RUN: would cd" "mclaude must NOT be launched after 'q'" || return 1
    assert_not_contains "$out" "launching anyway" "must not fall through to 'launching anyway' branch" || return 1
}
run_test "live lock + 'q' → abort, no launch" test_live_lock_q_aborts

# ── Case 3: live lock + empty (Enter) → private copy, NOT quit ────────────────
# CFG-533. Was "Enter = quit". A user new to the fleet (Max Pettinger, 2026-08-21)
# read the prompt, did not know what a worktree was, pressed Enter, and reported
# the multi-session feature as broken. Enter must now take the safe path, which is
# the one that loses no work: a private copy. Quitting is the destructive answer
# here — it throws away the user's intent to work.

test_live_lock_enter_takes_private_copy() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    printf '\n' > "$TEST_TMPDIR/answer-enter"
    local out rc=0
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-enter" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha 2>&1) || rc=$?

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    assert_eq "0" "$rc" || return 1
    assert_contains "$out" "DRY_RUN: would cd to $home/.afleet-worktrees/alpha-" \
        "Enter must open a private copy, not quit" || return 1
    # The other session's lock must survive untouched.
    local lock_content
    lock_content=$(cat "$project/.claude/.session-lock")
    assert_contains "$lock_content" "\"pid\":$other_pid" "main lock must not be clobbered" || return 1
}
run_test "live lock + Enter → private copy (not quit)" test_live_lock_enter_takes_private_copy

# ── Case 3b: 'j' and 'y' are accepted as yes ──────────────────────────────────
# The user is Austrian and the fleet is bilingual; 'j' for ja must not silently quit.

test_live_lock_ja_takes_private_copy() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    printf 'j\n' > "$TEST_TMPDIR/answer-ja"
    local out rc=0
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-ja" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha 2>&1) || rc=$?

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    assert_contains "$out" "DRY_RUN: would cd to $home/.afleet-worktrees/alpha-" \
        "'j' (ja) must open a private copy" || return 1
}
run_test "live lock + 'j' → private copy" test_live_lock_ja_takes_private_copy

# ── Case 4: unknown input re-asks instead of silently quitting ────────────────
# The old prompt mapped EVERY unrecognised keystroke to quit with no feedback, so
# a user who typed anything hopeful ('?', 'help', 'yes') was told only
# "Session not started." Unknown input must say so and re-offer the choice.

test_live_lock_garbage_reprompts_then_quits() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    # garbage, then an explicit quit
    printf 'xyz\nq\n' > "$TEST_TMPDIR/answer-garbage"
    local out rc=0
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-garbage" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha 2>&1) || rc=$?

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    assert_eq "0" "$rc" || return 1
    assert_contains "$out" "not one of the options" "garbage must be named as such, not silently quit" || return 1
    assert_not_contains "$out" "DRY_RUN: would cd" "explicit quit after garbage must not launch" || return 1
}
run_test "live lock + garbage → re-asks, then quits on 'q'" test_live_lock_garbage_reprompts_then_quits

# ── Case 4b: '?' explains without scolding ───────────────────────────────────

test_live_lock_question_mark_explains() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    printf '?\nq\n' > "$TEST_TMPDIR/answer-help"
    local out
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-help" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha 2>&1) || true

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    assert_not_contains "$out" "not one of the options" "'?' is a valid request, not an error" || return 1
    # explanation appears at least twice: once up front, once for '?'
    local n
    n=$(printf '%s\n' "$out" | grep -c 'private copy' || true)
    [ "${n:-0}" -ge 2 ] || { printf "    expected explanation twice, saw %s\n" "$n" >&2; return 1; }
}
run_test "live lock + '?' → explains again, no scolding" test_live_lock_question_mark_explains

# ── Case 4c: prompt is comprehensible to someone who does not know the jargon ──
# The regression this whole group exists for: the prompt described the safe option
# ONLY as "Open in isolated git worktree (follower mode)" — three unexplained terms.

test_prompt_explains_in_plain_language() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    printf 'q\n' > "$TEST_TMPDIR/answer-plain"
    local out
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-plain" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha 2>&1) || true

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    assert_contains "$out" "private copy" "safe option must be described in plain words" || return 1
    assert_contains "$out" "not disturbed" "must say the other session is unaffected" || return 1
    assert_contains "$out" "[?]" "must offer a way to ask what this means" || return 1
}
run_test "prompt explains itself in plain language" test_prompt_explains_in_plain_language

# ── Case 4d: no interactive terminal → quit, never an unattended worktree ─────

test_no_tty_does_not_create_worktree() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    : > "$TEST_TMPDIR/answer-empty"   # immediate EOF
    local out rc=0
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-empty" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha </dev/null 2>&1) || rc=$?

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    assert_eq "0" "$rc" || return 1
    assert_not_contains "$out" "DRY_RUN: would cd" "EOF must not launch" || return 1
    if [ -d "$home/.afleet-worktrees" ]; then
        printf "    EOF must not create a worktree unattended\n" >&2
        return 1
    fi
}
run_test "no answer possible (EOF) → quit, no worktree" test_no_tty_does_not_create_worktree

# ── Case 5: prompt must NOT offer steal / continue-anyway ─────────────────────

test_prompt_has_no_steal_option() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    # CFG-670: same seam, same reason as case 2 above.
    printf 'q\n' > "$TEST_TMPDIR/answer-q-nosteal"
    local out
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-q-nosteal" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha </dev/null 2>&1) || true

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    assert_not_contains "$out" "Continue anyway" "old Y/N prompt text must be gone" || return 1
    assert_not_contains "$out" "(y/N)" "no y/N prompt" || return 1
    assert_contains "$out" "worktree" "must mention worktree option" || return 1
}
run_test "prompt has no steal option, mentions worktree" test_prompt_has_no_steal_option

# ── Case 6: live lock + 'w' → creates worktree under ~/.afleet-worktrees ──────

test_live_lock_w_creates_worktree() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    sleep 60 & local other_pid=$!
    write_live_lock "$project" "$other_pid"

    local out
    out=$(printf 'w\n' | CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha 2>&1) || true

    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true

    # Worktree dir must exist under the sandbox HOME
    local wt_root="$home/.afleet-worktrees"
    assert_dir_exists "$wt_root" "worktree root must be under \$HOME/.afleet-worktrees" || return 1
    # At least one alpha worktree subdirectory
    local count
    count=$(find "$wt_root" -maxdepth 1 -mindepth 1 -type d -name 'alpha-*' 2>/dev/null | wc -l)
    assert_neq "0" "$count" "at least one alpha-* worktree subdir must be created" || return 1

    # DRY_RUN must now target the worktree path, not the main repo
    assert_contains "$out" "DRY_RUN: would cd to $wt_root/alpha-" \
        "DRY_RUN should cd into worktree, not main project" || return 1

    # Main project's lock file must be UNTOUCHED (still the other session's)
    assert_file_exists "$project/.claude/.session-lock" || return 1
    local lock_content
    lock_content=$(cat "$project/.claude/.session-lock")
    assert_contains "$lock_content" "\"pid\":$other_pid" "main lock must not be clobbered" || return 1
}
run_test "live lock + 'w' → worktree created, main lock preserved" test_live_lock_w_creates_worktree

# ── Case 7: stale lock (dead PID) → auto-clears, launches normally ────────────

test_stale_lock_auto_clears() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    # Pick a PID that's definitely dead — spawn and wait for it
    ( : ) & local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true
    write_live_lock "$project" "$dead_pid"

    local out rc=0
    out=$(CONFIG_REPO="$env" HOME="$home" PATH="$home/.local/bin:$PATH" \
        AFLEET_DRY_RUN=1 bash "$SCRIPT" alpha </dev/null 2>&1) || rc=$?

    assert_eq "0" "$rc" "stale lock must not block" || return 1
    assert_contains "$out" "DRY_RUN: would cd to $project" "stale lock should auto-clear and launch" || return 1
}
run_test "stale lock (dead PID) auto-clears and launches" test_stale_lock_auto_clears

# ── Case 8: post_session_cleanup with empty worktree → auto-removes ───────────

test_cleanup_removes_empty_worktree() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    # Manually create a worktree as the fix's code would
    local wt="$home/.afleet-worktrees/alpha-testempty"
    git -C "$project" worktree add -q -b afleet-wt-testempty "$wt"

    # Source afleet.sh in library mode
    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env" HOME="$home" \
        source "$SCRIPT" 2>/dev/null

    TARGET_DIR="$wt"
    TARGET_NAME="alpha"
    AFLEET_WORKTREE_MODE=1
    AFLEET_WORKTREE_MAIN="$project"
    AFLEET_WORKTREE_BRANCH="afleet-wt-testempty"
    MCLAUDE_EXIT=0

    # Run cleanup — should remove worktree since it's empty
    # Subshell because post_session_cleanup ends with `exit $MCLAUDE_EXIT`
    ( post_session_cleanup </dev/null >/dev/null 2>&1 ) || true

    assert_file_not_exists "$wt/CLAUDE.md" "empty worktree should be removed" || return 1
    # Branch should also be gone
    if git -C "$project" rev-parse --verify afleet-wt-testempty >/dev/null 2>&1; then
        printf "${RED}    branch afleet-wt-testempty should have been deleted${RESET}\n" >&2
        return 1
    fi
}
run_test "cleanup removes empty worktree and branch" test_cleanup_removes_empty_worktree

# ── Case 9: cleanup with commits + 'n' → preserves worktree ──────────────────

test_cleanup_preserves_worktree_on_no() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    local wt="$home/.afleet-worktrees/alpha-testpreserve"
    git -C "$project" worktree add -q -b afleet-wt-testpreserve "$wt"
    echo "content" > "$wt/file.txt"
    git -C "$wt" add -A
    git -C "$wt" -c user.name=t -c user.email=t@t commit -q -m "wt commit"

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env" HOME="$home" \
        source "$SCRIPT" 2>/dev/null

    TARGET_DIR="$wt"
    TARGET_NAME="alpha"
    AFLEET_WORKTREE_MODE=1
    AFLEET_WORKTREE_MAIN="$project"
    AFLEET_WORKTREE_BRANCH="afleet-wt-testpreserve"
    MCLAUDE_EXIT=0

    # Feed the answer through the prompt's own input seam, not stdin: the real
    # read targets /dev/tty, which wins over a pipe wherever a controlling
    # terminal exists (CFG-474).
    printf 'n\n' > "$TEST_TMPDIR/answer-n"
    AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-n" run_bounded 15 post_session_cleanup || return 1

    assert_file_exists "$wt/file.txt" "worktree should be preserved after 'n' answer" || return 1
    if ! git -C "$project" rev-parse --verify afleet-wt-testpreserve >/dev/null 2>&1; then
        printf "${RED}    branch afleet-wt-testpreserve should still exist${RESET}\n" >&2
        return 1
    fi
}
run_test "cleanup preserves worktree after 'n'" test_cleanup_preserves_worktree_on_no

# ── Case 10: cleanup with commits + 'y' ff-mergeable → merges and removes ─────

test_cleanup_merges_on_yes() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    local wt="$home/.afleet-worktrees/alpha-testmerge"
    git -C "$project" worktree add -q -b afleet-wt-testmerge "$wt"
    echo "merged content" > "$wt/merged.txt"
    git -C "$wt" add -A
    git -C "$wt" -c user.name=t -c user.email=t@t commit -q -m "wt merge commit"

    AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env" HOME="$home" \
        source "$SCRIPT" 2>/dev/null

    TARGET_DIR="$wt"
    TARGET_NAME="alpha"
    AFLEET_WORKTREE_MODE=1
    AFLEET_WORKTREE_MAIN="$project"
    AFLEET_WORKTREE_BRANCH="afleet-wt-testmerge"
    MCLAUDE_EXIT=0

    printf 'y\n' > "$TEST_TMPDIR/answer-y"
    AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-y" run_bounded 15 post_session_cleanup || return 1

    # Main repo main branch should now contain merged.txt
    assert_file_exists "$project/merged.txt" "merged file should now be in main branch" || return 1
    # Worktree and branch should be gone
    assert_file_not_exists "$wt/merged.txt" "worktree should be removed after merge" || return 1
    if git -C "$project" rev-parse --verify afleet-wt-testmerge >/dev/null 2>&1; then
        printf "${RED}    branch afleet-wt-testmerge should have been deleted${RESET}\n" >&2
        return 1
    fi
}
run_test "cleanup ff-merges worktree and removes on 'y'" test_cleanup_merges_on_yes

# ── Case 11 (CFG-474): the prompt must not block when a real terminal exists ──
# The cleanup prompt reads /dev/tty, which wins over a pipe. Every runner that
# lacks a controlling terminal silently took the fallback path, so this suite
# passed in CI and hung forever the moment a human ran it — 128 tests in, with
# no summary and no exit code. `script` allocates a pty, reproducing that exact
# condition, so this test fails by timeout if the input seam ever regresses.

test_prompt_does_not_block_under_a_real_tty() {
    local pair env home
    pair=$(build_env); env="${pair%|*}"; home="${pair#*|}"
    local project="$home/alpha"
    init_project "$project"

    local wt="$home/.afleet-worktrees/alpha-ttyseam"
    git -C "$project" worktree add -q -b afleet-wt-ttyseam "$wt"
    echo "content" > "$wt/file.txt"
    git -C "$wt" add -A
    git -C "$wt" -c user.name=t -c user.email=t@t commit -q -m "wt commit"

    printf 'n\n' > "$TEST_TMPDIR/answer-tty"

    cat > "$TEST_TMPDIR/run-cleanup.sh" << EOF
#!/usr/bin/env bash
AFLEET_SOURCE_ONLY=1 CONFIG_REPO="$env" HOME="$home" source "$SCRIPT" 2>/dev/null
TARGET_DIR="$wt"
TARGET_NAME="alpha"
AFLEET_WORKTREE_MODE=1
AFLEET_WORKTREE_MAIN="$project"
AFLEET_WORKTREE_BRANCH="afleet-wt-ttyseam"
MCLAUDE_EXIT=0
( AFLEET_PROMPT_INPUT="$TEST_TMPDIR/answer-tty" post_session_cleanup >/dev/null 2>&1 ) || true
touch "$TEST_TMPDIR/cleanup-returned"
EOF
    chmod +x "$TEST_TMPDIR/run-cleanup.sh"

    # Assert on a marker FILE, not on script(1)'s stdout: whether `script`
    # mirrors to a pipe varies with whether the caller itself owns a terminal,
    # which made an stdout-based assertion pass standalone and fail under
    # run.sh in tmux. stdin is /dev/null so script never contends for the
    # caller's terminal; the child still gets its own pty, which is the whole
    # point of the reproduction.
    timeout 20 script -q -e -c "bash $TEST_TMPDIR/run-cleanup.sh" /dev/null \
        </dev/null >/dev/null 2>&1 || true

    assert_file_exists "$TEST_TMPDIR/cleanup-returned" \
        "cleanup prompt must return when a controlling terminal exists" || return 1
    assert_file_exists "$wt/file.txt" "'n' answer must still preserve the worktree" || return 1
}
run_test "cleanup prompt does not block under a real tty (CFG-474)" test_prompt_does_not_block_under_a_real_tty

suite_summary
