#!/usr/bin/env bash
# Tests for global/hooks/checks/25-tmp-lint.sh — CFG-490 part (2).
#
# 2026-06-25: `git add -A` staged 46,964 untracked tmp files in a project. `tmp/` is the
# fleet's throwaway directory and must be gitignored with nothing tracked under it
# (three projects were outliers at report time). Every session checks its own
# project; a cfg-agent-fleet session sweeps every registered project with a local
# checkout.
source "$(dirname "$0")/test-helpers.sh"

CHECK="$REPO_ROOT/global/hooks/checks/25-tmp-lint.sh"

suite_header "check 25: tmp-lint (CFG-490)"

_repo() {  # <dir> <ignored:yes|no> [tracked-count]
    mkdir -p "$1/tmp"
    git -C "$1" init -q -b main
    [ "$2" = yes ] && printf 'tmp/\n' > "$1/.gitignore"
    printf 'x\n' > "$1/README.md"
    local i
    for i in $(seq 1 "${3:-0}"); do printf '%s\n' "$i" > "$1/tmp/t$i.txt"; git -C "$1" add -f "tmp/t$i.txt"; done
    git -C "$1" add -A && git -C "$1" commit -qm init
}

_cfg() {
    CONFIG_REPO="$TEST_TMPDIR/cfg"
    mkdir -p "$CONFIG_REPO"
    cat > "$CONFIG_REPO/registry.md" <<'EOF'
# Project Registry

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| goodproj | P1 | — | `~/goodproj` | x | wsl | code | active | ok |
| badproj | P2 | — | `~/badproj` | x | wsl | code | active | bad |
| trackproj | P2 | — | `~/trackproj` | x | wsl | code | active | tracked |
| ghostproj | P3 | — | `~/ghostproj` | x | wsl | code | active | not on this machine |
EOF
}

_run() {
    WARNINGS=""
    # shellcheck disable=SC1090
    source "$CHECK"
    printf '%s' "$WARNINGS"
}

t_clean_project_silent() {
    _cfg; _repo "$HOME/goodproj" yes
    PROJECT_DIR="$HOME/goodproj"
    assert_eq "" "$(_run)" "tmp/ ignored and nothing tracked: nothing to say"
}
run_test "a clean project is silent" t_clean_project_silent

t_not_ignored_flagged() {
    _cfg; _repo "$HOME/badproj" no
    PROJECT_DIR="$HOME/badproj"
    local w; w=$(_run)
    assert_contains "$w" "badproj" "the project must be named" || return 1
    assert_contains "$w" "tmp/ is not gitignored" "and the defect stated"
}
run_test "tmp/ not gitignored is flagged" t_not_ignored_flagged

t_tracked_flagged() {
    _cfg; _repo "$HOME/trackproj" yes 3
    PROJECT_DIR="$HOME/trackproj"
    local w; w=$(_run)
    assert_contains "$w" "3 tracked file(s) under tmp/" "tracked tmp files must be counted"
}
run_test "tracked files under tmp/ are flagged with their count" t_tracked_flagged

# A placeholder that keeps an otherwise-ignored tmp/ in the tree is deliberate, and
# flagging it at every startup forever trains people to ignore the warning (CFG-658).
t_placeholder_silent() {
    _cfg
    local d="$HOME/goodproj"
    mkdir -p "$d/tmp"; git -C "$d" init -q -b main
    printf '*\n!.gitignore\n' > "$d/tmp/.gitignore"      # the self-ignoring tmp/ idiom
    printf 'tmp/*\n!tmp/.gitignore\n!tmp/.gitkeep\n' > "$d/.gitignore"
    : > "$d/tmp/.gitkeep"; printf 'x\n' > "$d/README.md"
    git -C "$d" add -A && git -C "$d" commit -qm init
    PROJECT_DIR="$d"
    assert_eq "" "$(_run)" "a tracked tmp/.gitkeep or tmp/.gitignore placeholder is not a leak"
}
run_test "a tracked tmp/.gitkeep / tmp/.gitignore placeholder is silent" t_placeholder_silent

t_non_git_silent() {
    _cfg; mkdir -p "$HOME/plain/tmp"
    PROJECT_DIR="$HOME/plain"
    assert_eq "" "$(_run)" "a directory that is not a git repo has nothing to commit"
}
run_test "a non-git project is silent" t_non_git_silent

t_cfg_session_sweeps_registry() {
    _cfg
    _repo "$CONFIG_REPO" yes
    _repo "$HOME/goodproj" yes; _repo "$HOME/badproj" no; _repo "$HOME/trackproj" yes 2
    PROJECT_DIR="$CONFIG_REPO"
    local w; w=$(_run)
    assert_contains "$w" "badproj: tmp/ is not gitignored" "the sweep must find badproj" || return 1
    assert_contains "$w" "trackproj: 2 tracked file(s) under tmp/" "and trackproj" || return 1
    assert_not_contains "$w" "goodproj" "a clean project stays out of the report" || return 1
    assert_not_contains "$w" "ghostproj" "a project not checked out here is skipped"
}
run_test "a cfg-agent-fleet session sweeps every registered project" t_cfg_session_sweeps_registry

t_other_session_checks_only_itself() {
    _cfg
    _repo "$HOME/goodproj" yes; _repo "$HOME/badproj" no
    PROJECT_DIR="$HOME/goodproj"
    assert_eq "" "$(_run)" "a project session reports only its own project"
}
run_test "a non-cfg session checks only its own project" t_other_session_checks_only_itself

suite_summary
