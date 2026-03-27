#!/usr/bin/env bash
# Check group 17: Fleet version update check (daily)
# Compares local .agent-fleet-version against upstream remote.
# If upstream has a newer version, surfaces a FLEET_UPDATE warning.
# Shared vars used: PROJECT_DIR, WARNINGS

# Allow override for testing
_FLEET_PROJECT_DIR="${PROJECT_DIR:-}"

# Must have a project dir
[ -n "$_FLEET_PROJECT_DIR" ] || return 0 2>/dev/null || true

# Read local version — skip if no version file
_fleet_local_version=""
if [ -f "$_FLEET_PROJECT_DIR/.agent-fleet-version" ]; then
    _fleet_local_version=$(cat "$_FLEET_PROJECT_DIR/.agent-fleet-version" 2>/dev/null | tr -d '[:space:]')
fi
[ -n "$_fleet_local_version" ] || return 0 2>/dev/null || true

# Must be a git repo with an upstream remote
git -C "$_FLEET_PROJECT_DIR" remote get-url upstream >/dev/null 2>&1 || return 0 2>/dev/null || true

# Daily gate via sched-lib (if available) or fallback to inline marker
_fleet_sched_lib="${CONFIG_REPO:-}/setup/scripts/sched-lib.sh"
if [ -f "$_fleet_sched_lib" ]; then
    source "$_fleet_sched_lib"
    SCHED_MARKER_DIR="${SCHED_MARKER_DIR:-/tmp}"
    sched_is_due "fleet-update-check" "daily" || return 0 2>/dev/null || true
else
    _fleet_gate="/tmp/.fleet-update-check-$(date +%Y-%m-%d)"
    [ ! -f "$_fleet_gate" ] || return 0 2>/dev/null || true
    touch "$_fleet_gate"
fi

# Get upstream version via git show (requires prior fetch — startup hook does this)
_fleet_upstream_version=""
for _branch in main master; do
    _fleet_upstream_version=$(git -C "$_FLEET_PROJECT_DIR" show "upstream/$_branch:.agent-fleet-version" 2>/dev/null | tr -d '[:space:]') && break
    _fleet_upstream_version=""
done
[ -n "$_fleet_upstream_version" ] || return 0 2>/dev/null || true

# Channel-aware filtering — read user's update channel preference
_fleet_channel="major"
_fleet_channel_file="$_FLEET_PROJECT_DIR/.agent-fleet-channel"
[ -f "$_fleet_channel_file" ] && _fleet_channel=$(cat "$_fleet_channel_file" 2>/dev/null | tr -d '[:space:]')

# Major channel: only consider X.0 or X.0.0 versions (skip minor bumps)
if [ "$_fleet_channel" = "major" ]; then
    # Strip upstream version to major: "1.2.3" → check if minor+patch are 0
    _fleet_minor=$(echo "$_fleet_upstream_version" | cut -d. -f2)
    _fleet_patch=$(echo "$_fleet_upstream_version" | cut -d. -f3)
    _fleet_minor="${_fleet_minor:-0}"
    _fleet_patch="${_fleet_patch:-0}"
    if [ "$_fleet_minor" != "0" ] || [ "$_fleet_patch" != "0" ]; then
        # Minor/patch release — skip for major-only users
        return 0 2>/dev/null || true
    fi
fi

# Compare versions — only warn if upstream is strictly newer
# Portable: try sort -V (GNU), fall back to dot-separated numeric sort (macOS)
if [ "$_fleet_local_version" = "$_fleet_upstream_version" ]; then
    return 0 2>/dev/null || true
fi
_fleet_newer=$(printf '%s\n%s' "$_fleet_local_version" "$_fleet_upstream_version" | sort -V 2>/dev/null || printf '%s\n%s' "$_fleet_local_version" "$_fleet_upstream_version" | sort -t. -k1,1n -k2,2n -k3,3n)
_fleet_newer=$(printf '%s' "$_fleet_newer" | tail -1)
if [ "$_fleet_newer" != "$_fleet_upstream_version" ]; then
    # Local is newer or equal — no update needed
    return 0 2>/dev/null || true
fi

# Mark done (sched-lib or fallback)
if type sched_mark_done &>/dev/null; then
    sched_mark_done "fleet-update-check" "daily"
elif [ -z "${_fleet_gate:-}" ]; then
    touch "/tmp/.fleet-update-check-$(date +%Y-%m-%d)"
fi

# Append warning
WARNINGS="${WARNINGS:+$WARNINGS | }FLEET_UPDATE: v${_fleet_local_version} → v${_fleet_upstream_version} available (${_fleet_channel} channel). Run 'upgrade.sh --check' to preview."
