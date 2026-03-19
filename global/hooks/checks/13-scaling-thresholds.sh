# Check group 13: File LOC scaling thresholds (daily)
# Surfaces warnings when files exceed size limits, suggesting refactoring or splitting.
# Shared vars used: CONFIG_REPO, WARNINGS

_SCALING_MARKER="/tmp/.scaling-check-$(date +%Y-%m-%d)"

# Daily gate — run once per day
[ -f "$_SCALING_MARKER" ] && return 0 2>/dev/null || true
[ -f "$_SCALING_MARKER" ] && exit 0 2>/dev/null || true

_scaling_violations=""
_scaling_count=0

# _check_files <glob_pattern> <soft_limit> <hard_limit> <category_label>
_check_files() {
    local pattern="$1" soft="$2" hard="$3" label="$4"
    local f lines fname
    # Use eval to expand the glob against CONFIG_REPO
    for f in $(eval echo "$pattern"); do
        [ -f "$f" ] || continue
        lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        [ "$lines" -le "$soft" ] 2>/dev/null && continue
        fname="${f#"$CONFIG_REPO"/}"
        if [ "$lines" -gt "$hard" ]; then
            _scaling_violations="${_scaling_violations:+$_scaling_violations; }${fname} (${lines}L) HARD LIMIT — must split ($label, hard=$hard)"
        else
            _scaling_violations="${_scaling_violations:+$_scaling_violations; }${fname} (${lines}L) soft limit ($label, warn=$soft)"
        fi
        _scaling_count=$((_scaling_count + 1))
    done
}

# Bash scripts: setup/scripts/*.sh, sync.sh
_check_files "$CONFIG_REPO/setup/scripts/*.sh" 400 600 "bash"
_check_files "$CONFIG_REPO/sync.sh" 400 600 "bash"

# Test files: setup/tests/*.sh
_check_files "$CONFIG_REPO/setup/tests/*.sh" 800 1500 "test"

# Knowledge/reference .md
_check_files "$CONFIG_REPO/global/knowledge/*.md" 200 350 "knowledge/ref"
_check_files "$CONFIG_REPO/global/reference/*.md" 200 350 "knowledge/ref"

# Hook check modules: global/hooks/checks/*.sh
_check_files "$CONFIG_REPO/global/hooks/checks/*.sh" 100 150 "hook-check"

# Hook scripts (non-checks): global/hooks/*.sh
_check_files "$CONFIG_REPO/global/hooks/*.sh" 200 300 "hook"

if [ "$_scaling_count" -gt 0 ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }SCALING: $_scaling_count file(s) exceed LOC thresholds: $_scaling_violations"
    touch "$_SCALING_MARKER"
fi
