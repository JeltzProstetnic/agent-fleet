#!/usr/bin/env bash
# Check group 17: Fleet version update check (daily; CFG-497, AFT-71)
# Compares the local .agent-fleet-version with the template remote's (`upstream`, else `origin`).
# Once a day per project: a bounded fetch (5 s, never prompts; on failure the cached ref is
# used), then a FLEET_UPDATE warning ending in the release's CHANGELOG headline.
# Channel (.agent-fleet-channel): minor (default: major + minor bumps, no patch-only),
# major (x.0.0 only), all or rolling (upgrade.sh's name): any newer version; unknown → minor.
# Shared vars used: PROJECT_DIR, CONFIG_REPO, WARNINGS. Every step guarded; doubt → return 0.

_FLEET_PROJECT_DIR="${PROJECT_DIR:-}"
[ -n "$_FLEET_PROJECT_DIR" ] || return 0 2>/dev/null || true
_fleet_git() { git -C "$_FLEET_PROJECT_DIR" "$@"; }

_fleet_local_version=""
[ -f "$_FLEET_PROJECT_DIR/.agent-fleet-version" ] &&
    _fleet_local_version=$(tr -d '[:space:]' 2>/dev/null < "$_FLEET_PROJECT_DIR/.agent-fleet-version")
[ -n "$_fleet_local_version" ] || return 0 2>/dev/null || true

# Template remote: `upstream` (derived install), else `origin` (direct clone), else silent
_fleet_remote=""
for _fleet_r in upstream origin; do
    _fleet_git remote get-url "$_fleet_r" >/dev/null 2>&1 && { _fleet_remote=$_fleet_r; break; }
done
[ -n "$_fleet_remote" ] || return 0 2>/dev/null || true

# Daily gate PER PROJECT, consumed before the fetch: one fetch per project per day, update
# or not, and one project's run never gates another's. sched-lib, else an inline marker.
_fleet_id=${_FLEET_PROJECT_DIR%/}; _fleet_id="fleet-update-check-${_fleet_id##*/}"
_fleet_id=${_fleet_id//[^A-Za-z0-9_-]/_}
_fleet_sched_lib="${CONFIG_REPO:-}/setup/scripts/sched-lib.sh"
if [ -f "$_fleet_sched_lib" ]; then
    source "$_fleet_sched_lib"
    sched_is_due "$_fleet_id" daily || return 0 2>/dev/null || true
    sched_mark_done "$_fleet_id" daily 2>/dev/null || true
else
    # fallback inline marker — never a bare /tmp (GH#13: read-only in the CC sandbox)
    _fleet_gate="${SCHED_MARKER_DIR:-${TMPDIR:-/tmp}}/.${_fleet_id}-$(date +%Y-%m-%d)"
    [ ! -f "$_fleet_gate" ] || return 0 2>/dev/null || true
    touch "$_fleet_gate" 2>/dev/null || true
fi

# Branch: the remote-tracking ref that exists (main first), else main
_fleet_branch=main
if ! _fleet_git rev-parse -q --verify "refs/remotes/$_fleet_remote/main" >/dev/null 2>&1 &&
    _fleet_git rev-parse -q --verify "refs/remotes/$_fleet_remote/master" >/dev/null 2>&1; then
    _fleet_branch=master
fi

# Bounded fetch: 5 s cap (lib-portable's _timeout, else `timeout`, else no fetch at all),
# stdin closed, every prompt path off. A failure or timeout is silent — the cached ref is used.
_fleet_to=timeout; type _timeout >/dev/null 2>&1 && _fleet_to=_timeout
if command -v "$_fleet_to" >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= GCM_INTERACTIVE=never "$_fleet_to" 5 \
        git -C "$_FLEET_PROJECT_DIR" fetch --quiet "$_fleet_remote" "$_fleet_branch" \
        </dev/null >/dev/null 2>&1 || true
fi

_fleet_ref="$_fleet_remote/$_fleet_branch"
_fleet_upstream_version=$(_fleet_git show "$_fleet_ref:.agent-fleet-version" 2>/dev/null | tr -d '[:space:]')
[ -n "$_fleet_upstream_version" ] || return 0 2>/dev/null || true

# _fleet_semver <version> → "MAJOR MINOR PATCH" (a missing or non-numeric part counts as 0)
_fleet_semver() {
    local a b c d; IFS=. read -r a b c d <<<"$1"
    a=${a%%[!0-9]*} b=${b%%[!0-9]*} c=${c%%[!0-9]*}
    echo "$((10#${a:-0})) $((10#${b:-0})) $((10#${c:-0}))"
}
# _fleet_bump <local> <upstream> → major | minor | patch | none (upstream not newer)
_fleet_bump() {
    local l u; l=($(_fleet_semver "$1")); u=($(_fleet_semver "$2"))
    if [ "${u[0]}" -ne "${l[0]}" ]; then [ "${u[0]}" -gt "${l[0]}" ] && echo major || echo none
    elif [ "${u[1]}" -ne "${l[1]}" ]; then [ "${u[1]}" -gt "${l[1]}" ] && echo minor || echo none
    elif [ "${u[2]}" -gt "${l[2]}" ]; then echo patch
    else echo none; fi
}

_fleet_channel=minor
[ -f "$_FLEET_PROJECT_DIR/.agent-fleet-channel" ] &&
    _fleet_channel=$(tr -d '[:space:]' 2>/dev/null < "$_FLEET_PROJECT_DIR/.agent-fleet-channel")
case "$_fleet_channel" in major|all|rolling) ;; *) _fleet_channel=minor ;; esac
case "$_fleet_channel:$(_fleet_bump "$_fleet_local_version" "$_fleet_upstream_version")" in
    *:none|minor:patch) return 0 2>/dev/null || true ;;
esac
if [ "$_fleet_channel" = major ]; then   # x.0.0 releases only
    case " $(_fleet_semver "$_fleet_upstream_version")" in *" 0 0") ;; *) return 0 2>/dev/null || true ;; esac
fi

# What's new: first non-empty, non-heading line of the CHANGELOG's `## [<version>]` section,
# markdown bold stripped, at most 120 chars. No CHANGELOG or no such section → no suffix.
_fleet_news=$(_fleet_git show "$_fleet_ref:CHANGELOG.md" 2>/dev/null |
    awk -v h="## [$_fleet_upstream_version]" '{ sub(/\r$/, "") }
        !f { if (index($0, h) == 1) f = 1; next }
        /^## / { exit }
        /^#/ || !NF { next }
        { gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }' | tr -d '[:cntrl:]')
_fleet_news=${_fleet_news//\*\*/}
_fleet_news=${_fleet_news:0:120}

WARNINGS="${WARNINGS:+$WARNINGS | }FLEET_UPDATE: v${_fleet_local_version} → v${_fleet_upstream_version} available (${_fleet_channel} channel). Run 'upgrade.sh --check' to preview.${_fleet_news:+ — $_fleet_news}"
