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

# CFG-977: while another live session holds the config repo, the difference is
# that session's in-progress work — deployed at its own shutdown — and "run
# sync.sh deploy" would put its half-edited tree live from here. Held ⇒ no
# warning, one audit line (CFG-965 drops the same lines from its drift log at
# shutdown). Lock state unknown ⇒ the warning stays, without the deploy advice.
# Verdict: lib-cfg-held.sh beside the deployed hooks (_CFG_HELD_LIB in tests),
# asked only when there is drift; 100 = library missing or unusable. Read-only:
# check_lock's stale-lock `rm` is a no-op here, as in afleet-cfg-held.sh.
_dd_held_rc() {
    local lib="${_CFG_HELD_LIB:-$(dirname "${BASH_SOURCE[0]}")/../lib-cfg-held.sh}" rc=0
    [ -f "$lib" ] || return 100
    ( rm() { :; }
      source "$lib" >/dev/null 2>&1 || exit 100
      declare -F _cfg_held_check_lock >/dev/null || exit 100
      _cfg_held_check_lock "$CONFIG_REPO" ) || rc=$?
    return "$rc"
}

if [ "$_drift_count" -gt 0 ]; then
    _dd_rc=0
    _dd_held_rc || _dd_rc=$?
    case "$_dd_rc" in
        0|1) _dd_state=free ;;
        2|3) _dd_state=held ;;
        5|100) if [ -f "$CONFIG_REPO/.claude/.session-lock" ]; then _dd_state=unknown; else _dd_state=free; fi ;;
        *) _dd_state=unknown ;;
    esac
    case "$_dd_state" in
        held)
            mkdir -p "$HOME/.claude/logs" 2>/dev/null
            printf '%s DEPLOYED_DRIFT_DEFERRED: config repo held by another live session — %s hook file(s) differ (its in-progress work, deployed at its own shutdown): %s (SessionStart of %s)\n' \
                "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" "$_drift_count" "$_drift_files" "$(basename "${PROJECT_DIR:-$PWD}")" \
                >> "$HOME/.claude/logs/template-push-deferred.log" 2>/dev/null || true ;;
        unknown)
            WARNINGS="${WARNINGS:+$WARNINGS | }DEPLOYED_DRIFT: $_drift_count hook file(s) differ between repo and deployed: $_drift_files. The config repo's lock state is unknown (check_lock=$_dd_rc) — this may be a live session's in-progress work: do not run sync.sh deploy while a session may hold $(basename "$CONFIG_REPO")." ;;
        *)
            WARNINGS="${WARNINGS:+$WARNINGS | }DEPLOYED_DRIFT: $_drift_count hook file(s) differ between repo and deployed: $_drift_files. Run 'sync.sh deploy' to fix." ;;
    esac
fi
