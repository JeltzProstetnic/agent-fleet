#!/usr/bin/env bash
# Tests for check 27: box-wide name-pattern kills inside a project's tracked scripts (CFG-730)
# kill-guard/pkill-guard only see commands an agent types. One project's stack script killed
# every pytest/ffmpeg process on the box at each start and took out a sibling project's test
# runs (2026-09-29). This check lints the project's own tracked scripts at startup. TDD: written first.
source "$(dirname "$0")/test-helpers.sh"
source "$(dirname "$0")/test-check-helpers.sh"

suite_header "config-check.sh: unscoped name-pattern kills in tracked scripts (check 27)"

_uk_setup() {
    local config_repo="$TEST_TMPDIR/config-repo"
    local mock_home="$TEST_TMPDIR/home"
    local project_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_home/.claude" "$project_dir/scripts" "$project_dir/tests"
    create_mock_config_repo "$config_repo"
    touch "$config_repo/CLAUDE.md"
    ln -sf "$config_repo/CLAUDE.md" "$mock_home/.claude/CLAUDE.md"
    create_mock_plugin_files "$mock_home"
    git -C "$project_dir" init -q
    create_patched_script "$config_repo" "$mock_home" "$project_dir"
}

_uk_field() {
    printf '%s' "$1" | grep -oE 'UNSCOPED_KILL:[^|]*' | head -1
}

_uk_track() {   # <relative path> — write stdin to it and git-add it
    cat > "$TEST_TMPDIR/project/$1"
    git -C "$TEST_TMPDIR/project" add "$1"
}

test_bare_name_kills_are_flagged() {
    local patched; patched=$(_uk_setup)
    _uk_track scripts/stack.sh <<'EOF'
#!/usr/bin/env bash
pkill -f pytest
echo start; killall ffmpeg || true
EOF
    _uk_track scripts/clean.py <<'EOF'
import subprocess
subprocess.run(["pkill", "-f", "ffprobe"])
EOF
    local output field
    output=$(run_hook "$patched")
    field=$(_uk_field "$output")
    assert_contains "$field" "3 " "three unscoped kills counted (measured field: '$field')" || return 1
    assert_contains "$field" "scripts/stack.sh:2"
    assert_contains "$field" "scripts/stack.sh:3"
    assert_contains "$field" "scripts/clean.py:2"
}
run_test "check 27: bare-name kills in bash and python are flagged with file:line" test_bare_name_kills_are_flagged

test_prose_and_scoped_forms_are_silent() {
    local patched; patched=$(_uk_setup)
    _uk_track scripts/ok.sh <<'EOF'
#!/usr/bin/env bash
# pkill -f pytest would kill every pytest on the box
echo "never run pkill -f pytest here"
printf 'pkill -f %s\n' "$x"
pkill -f "repro/moc7_slice3_learning.py|repro/cru188_vision"
pkill -f runner.py
kill "$PID"
pkill -f ffmpeg   # kill-scope: ok (container-only helper)
PID=$(pgrep -f "python.*-m project gallery" 2>/dev/null)
kill "$PID" 2>/dev/null
EOF
    _uk_track scripts/doc.py <<'EOF'
"""``pkill -f <pattern>`` signals every matching process on the machine."""
EOF
    _uk_track tests/test_x.sh <<'EOF'
pkill -f pytest
EOF
    local output
    output=$(run_hook "$patched")
    assert_not_contains "$output" "UNSCOPED_KILL" "comments, prose, path/script-scoped patterns, PID kills, marked lines and test files stay silent"
}
run_test "check 27: prose, scoped patterns, PID kills, opt-outs and tests are silent" test_prose_and_scoped_forms_are_silent

test_untracked_and_non_git_are_silent() {
    local patched; patched=$(_uk_setup)
    printf 'pkill -f pytest\n' > "$TEST_TMPDIR/project/scripts/untracked.sh"
    local output
    output=$(run_hook "$patched")
    assert_not_contains "$output" "UNSCOPED_KILL" "an untracked file is not the project's script yet"
    rm -rf "$TEST_TMPDIR/project/.git"
    output=$(run_hook "$patched")
    assert_not_contains "$output" "UNSCOPED_KILL" "a project that is not a git repo stays silent"
}
run_test "check 27: untracked files and non-git projects are silent" test_untracked_and_non_git_are_silent

# The real 2026-09-29 incident used no pkill at all: a helper filled a variable from pgrep and
# killed it, and the call sites passed bare names. Lint the idiom, not just the command word.
test_pgrep_kill_helper_is_flagged_at_call_sites() {
    local patched; patched=$(_uk_setup)
    _uk_track scripts/stack.sh <<'EOF'
#!/usr/bin/env bash
kill_by_pattern() {
    local pattern="$1" label="$2"
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        kill -TERM $pids 2>/dev/null || true
    fi
}
kill_by_pattern "python.*${SERVER_MODULE//./\\.}" "server"
kill_by_pattern "pytest" "orphaned pytest"
kill -9 $(pgrep -f ffmpeg)
pgrep -f ffplay | xargs kill
EOF
    local output field
    output=$(run_hook "$patched")
    field=$(_uk_field "$output")
    assert_contains "$field" "3 " "helper call with a bare name + two inline pgrep kills (measured field: '$field')" || return 1
    assert_contains "$field" "scripts/stack.sh:11" "the call site passing a bare name is the finding"
    assert_not_contains "$field" "scripts/stack.sh:10" "a call site passing a variable-built pattern is not"
    assert_contains "$field" "scripts/stack.sh:12"
    assert_contains "$field" "scripts/stack.sh:13"
}
run_test "check 27: pgrep-then-kill helpers and inline pgrep kills are flagged" test_pgrep_kill_helper_is_flagged_at_call_sites

# Pattern 11: prove the lint on the real artifact that caused CFG-730, when it is on this box.
test_real_incident_file_is_flagged() {
    # Opt-in: CFG730_INCIDENT_REPO=<repo> CFG730_INCIDENT_BLOB=<rev:path> CFG730_INCIDENT_LINE=<n>
    # (the template carries no project paths). Verified 2026-09-29 on the source machine: flagged.
    local repo="${CFG730_INCIDENT_REPO:-}" blob="${CFG730_INCIDENT_BLOB:-}" line="${CFG730_INCIDENT_LINE:-}"
    if [[ -z "$repo" || -z "$blob" || -z "$line" ]] || ! git -C "$repo" cat-file -e "$blob" 2>/dev/null; then
        skip_test "real incident file" "set CFG730_INCIDENT_REPO/_BLOB/_LINE to run it"; return 0
    fi
    local patched; patched=$(_uk_setup)
    git -C "$repo" show "$blob" | _uk_track scripts/incident.sh
    local output field
    output=$(run_hook "$patched")
    field=$(_uk_field "$output")
    assert_contains "$field" "scripts/incident.sh:$line" "the pre-fix incident script 'kill_by_pattern pytest' is caught (measured field: '$field')"
}
run_test "check 27: the real pre-fix incident script is flagged (opt-in)" test_real_incident_file_is_flagged

test_listing_is_capped() {
    local patched; patched=$(_uk_setup)
    { echo '#!/usr/bin/env bash'; for i in $(seq 1 8); do echo "pkill -f worker$i"; done; } | _uk_track scripts/many.sh
    local output field
    output=$(run_hook "$patched")
    field=$(_uk_field "$output")
    assert_contains "$field" "8 " "full count reported (measured field: '$field')" || return 1
    assert_contains "$field" "+3 more" "listing capped at five locations"
}
run_test "check 27: listing is capped at five locations plus an overflow count" test_listing_is_capped

suite_summary
