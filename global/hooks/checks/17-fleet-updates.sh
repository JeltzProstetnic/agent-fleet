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

# Daily gate — only check once per day
_fleet_gate="/tmp/.fleet-update-check-$(date +%Y-%m-%d)"
[ ! -f "$_fleet_gate" ] || return 0 2>/dev/null || true
touch "$_fleet_gate"

# Get upstream version via git show (requires prior fetch — startup hook does this)
_fleet_upstream_version=""
for _branch in main master; do
    _fleet_upstream_version=$(git -C "$_FLEET_PROJECT_DIR" show "upstream/$_branch:.agent-fleet-version" 2>/dev/null | tr -d '[:space:]') && break
    _fleet_upstream_version=""
done
[ -n "$_fleet_upstream_version" ] || return 0 2>/dev/null || true

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

# Append warning
WARNINGS="${WARNINGS:+$WARNINGS | }FLEET_UPDATE: v${_fleet_local_version} → v${_fleet_upstream_version} available. Run 'upgrade.sh --check' to preview."
