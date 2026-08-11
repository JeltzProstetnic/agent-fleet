#!/usr/bin/env bash
# Check group 16: Deployed vs repo hook drift
# Compares deployed hooks (~/.claude/hooks/) against repo source (global/hooks/).
# Catches cases where sync.sh deploy wasn't run after a git pull.
# Deployed hooks have a managed header injected by deploy_hooks() — strip it before comparing.
# Shared vars used: CONFIG_REPO, WARNINGS

# Allow override for testing
_DEPLOYED_HOOKS_DIR="${_DEPLOYED_HOOKS_DIR:-$HOME/.claude/hooks}"
_REPO_HOOKS_DIR="$CONFIG_REPO/global/hooks"

[ -d "$_DEPLOYED_HOOKS_DIR" ] || return 0 2>/dev/null || true
[ -d "$_REPO_HOOKS_DIR" ] || return 0 2>/dev/null || true

_drift_files=""
_drift_count=0

# Compare hook content, stripping the managed header from deployed copy (CFG-299)
_compare_hook() {
    local repo_file="$1" deployed_file="$2"
    # Deployed hooks have "# MANAGED" as line 2 (after shebang). Strip it before diff.
    diff <(cat "$repo_file") <(sed '/^# MANAGED/d' "$deployed_file") >/dev/null 2>&1
}

# Compare top-level hook scripts
for _repo_file in "$_REPO_HOOKS_DIR"/*.sh; do
    [ -f "$_repo_file" ] || continue
    _fname="$(basename "$_repo_file")"
    _deployed_file="$_DEPLOYED_HOOKS_DIR/$_fname"
    [ -f "$_deployed_file" ] || continue
    if ! _compare_hook "$_repo_file" "$_deployed_file"; then
        _drift_files="${_drift_files:+$_drift_files, }$_fname"
        _drift_count=$((_drift_count + 1))
    fi
done

# Compare checks/ subdirectory
if [ -d "$_REPO_HOOKS_DIR/checks" ] && [ -d "$_DEPLOYED_HOOKS_DIR/checks" ]; then
    for _repo_file in "$_REPO_HOOKS_DIR/checks"/*.sh; do
        [ -f "$_repo_file" ] || continue
        _fname="$(basename "$_repo_file")"
        _deployed_file="$_DEPLOYED_HOOKS_DIR/checks/$_fname"
        [ -f "$_deployed_file" ] || continue
        if ! _compare_hook "$_repo_file" "$_deployed_file"; then
            _drift_files="${_drift_files:+$_drift_files, }checks/$_fname"
            _drift_count=$((_drift_count + 1))
        fi
    done
fi

if [ "$_drift_count" -gt 0 ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }DEPLOYED_DRIFT: $_drift_count hook file(s) differ between repo and deployed: $_drift_files. Run 'sync.sh deploy' to fix."
fi
