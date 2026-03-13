#!/usr/bin/env bash
# fleet-issue.sh — Privacy scrubber, dedup checker, formatter for fleet-to-GitHub issue filing
# Part of CFG-73: Fleet-to-GitHub Issue Feedback System
#
# Usage:
#   fleet-issue.sh --scrub <body_file>                          # Privacy check only
#   fleet-issue.sh --dedup <title> [index_file]                 # Check local dedup index
#   fleet-issue.sh --record <title> <issue_number> [index_file] # Record filed issue
#   fleet-issue.sh --format <title> <category> <severity> <body_file> # Format + scrub
#
# Exit codes:
#   0 = clean / success
#   1 = privacy violation found / error
#   2 = duplicate found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default dedup index location
DEFAULT_INDEX="$HOME/.claude/.fleet-issues.jsonl"

# ── Privacy Patterns ─────────────────────────────────────────────────────────
# Extended from sync.sh PERSONAL_DATA_PATTERNS, plus additional categories.
# Each pattern array entry is: "category|regex"
# Using arrays so we can report which category matched.

PRIVACY_PATTERNS=(
    # ── CUSTOMIZE THESE PATTERNS WITH YOUR ACTUAL DATA ──
    # Each entry is "category|regex" (extended regex, case-insensitive matching).
    # Uncomment and fill in your personal patterns below.
    # The placeholder pattern below catches accidental inclusion of the config marker.
    "placeholder|CUSTOMIZE_PRIVACY_PATTERNS"

    # Machine hostnames
    # "hostname|DESKTOP-[A-Za-z0-9]+"
    # "hostname|my-server-[0-9]+"

    # Home paths (your usernames)
    # "home_path|/home/myuser/"
    # "home_path|/root/"

    # Private repo names (repos not in the public template)
    # "private_repo|my-private-config"
    # "private_repo|corporate-repo"

    # SSH hosts/IPs
    # "ssh_host|192\.168\.1\.100"
    # "ssh_host|10\.0\.0\.50"

    # Email domains
    # "email|[a-zA-Z0-9._%+-]+@example\.com"
    # "email|[a-zA-Z0-9._%+-]+@corporate\.com"

    # NAS/device hostnames
    # "nas|my-nas-device"

    # Personal names / usernames
    # "personal_name|Your Name"
    # "personal_name|\busername\b"

    # GitHub accounts/orgs
    # "github_account|MyGitHubUser"
    # "github_account|MyOrgName"
)

# ── Functions ────────────────────────────────────────────────────────────────

usage() {
    cat >&2 << 'EOF'
Usage:
  fleet-issue.sh --scrub <body_file>
  fleet-issue.sh --dedup <title> [index_file]
  fleet-issue.sh --record <title> <issue_number> [index_file]
  fleet-issue.sh --format <title> <category> <severity> <body_file>

Exit codes: 0=clean, 1=privacy violation/error, 2=duplicate found
EOF
    exit 1
}

# scrub_check <file>
# Returns 0 if clean, 1 if privacy violations found.
# Prints offending patterns to stdout on violation.
scrub_check() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "Error: Body file '$file' not found" >&2
        return 1
    fi

    local content
    content=$(<"$file")
    local violations=()
    local seen_categories=()

    for entry in "${PRIVACY_PATTERNS[@]}"; do
        local category="${entry%%|*}"
        local pattern="${entry#*|}"

        if echo "$content" | grep -qEi "$pattern"; then
            # Extract the matching text for the report
            local match
            match=$(echo "$content" | grep -oEi "$pattern" | head -1)
            # Avoid duplicate category+match reports
            local key="${category}:${match}"
            local already_seen=false
            for seen in "${seen_categories[@]+"${seen_categories[@]}"}"; do
                if [[ "$seen" == "$key" ]]; then
                    already_seen=true
                    break
                fi
            done
            if [[ "$already_seen" == "false" ]]; then
                violations+=("[$category] $match")
                seen_categories+=("$key")
            fi
        fi
    done

    if [[ ${#violations[@]} -gt 0 ]]; then
        echo "Privacy violations found:"
        for v in "${violations[@]}"; do
            echo "  - $v"
        done
        return 1
    fi

    echo "Clean — no privacy violations detected."
    return 0
}

# dedup_check <title> [index_file]
# Returns 0 if no duplicate, 2 if duplicate found.
dedup_check() {
    local title="$1"
    local index="${2:-$DEFAULT_INDEX}"

    # No index file = no duplicates
    if [[ ! -f "$index" ]]; then
        return 0
    fi

    # Empty file = no duplicates
    if [[ ! -s "$index" ]]; then
        return 0
    fi

    local title_lower
    title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')

    # Check each entry in the index
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Extract title from JSON (simple parsing — no jq dependency)
        local existing_title
        existing_title=$(echo "$line" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')
        local existing_lower
        existing_lower=$(echo "$existing_title" | tr '[:upper:]' '[:lower:]')

        # Exact match (case-insensitive)
        if [[ "$title_lower" == "$existing_lower" ]]; then
            echo "Potential duplicate found (exact match): '$existing_title'"
            return 2
        fi

        # Fuzzy match: new title is substring of existing, or existing is substring of new
        if [[ "$existing_lower" == *"$title_lower"* ]] || [[ "$title_lower" == *"$existing_lower"* ]]; then
            echo "Potential duplicate found (fuzzy match): '$existing_title'"
            return 2
        fi
    done < "$index"

    return 0
}

# record_issue <title> <issue_number> [index_file]
# Appends a JSONL entry to the dedup index.
record_issue() {
    local title="$1"
    local number="$2"
    local index="${3:-$DEFAULT_INDEX}"
    local date
    date=$(date +%Y-%m-%d)

    # Ensure parent directory exists
    local index_dir
    index_dir=$(dirname "$index")
    mkdir -p "$index_dir"

    echo "{\"title\":\"$title\",\"number\":$number,\"date\":\"$date\"}" >> "$index"
}

# format_metadata
# Outputs the Fleet Metadata section with anonymized machine name.
format_metadata() {
    local anon_machine="a fleet machine"
    local session_date
    session_date=$(date +%Y-%m-%d)
    local config_version=""

    # Try to get git short hash from the repo
    if [[ -d "$REPO_ROOT/.git" ]] || git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        config_version=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    else
        config_version="unknown"
    fi

    cat << EOF
---
<details>
<summary>Fleet Metadata</summary>

- Machine: $anon_machine
- Session: $session_date
- Source: relates to internal tracking
- Config version: $config_version
</details>
EOF
}

# format_body <title> <category> <severity> <body_file>
# Outputs the full formatted issue body. Runs scrub first.
format_body() {
    local title="$1"
    local category="$2"
    local severity="$3"
    local body_file="$4"

    if [[ ! -f "$body_file" ]]; then
        echo "Error: Body file '$body_file' not found" >&2
        return 1
    fi

    # Run privacy scrub first
    local scrub_output
    scrub_output=$(scrub_check "$body_file" 2>&1) || {
        echo "$scrub_output"
        return 1
    }

    local body_content
    body_content=$(<"$body_file")

    cat << EOF
## Description
$body_content

## Context
- **Category:** $category
- **Discovered via:** manual-report
- **Severity:** $severity

## Reproduction / Rationale
_(see description)_

## Proposed Solution
_(to be determined)_

$(format_metadata)
EOF
}

# check_stale <index_file> <max_age_days>
# Reports entries older than max_age_days. Returns 0 if all fresh, 1 if stale found.
check_stale() {
    local index="$1"
    local max_age="$2"
    if [[ ! -f "$index" ]] || [[ ! -s "$index" ]]; then
        echo "No dedup index or empty — nothing stale."
        return 0
    fi
    local today_epoch stale_count=0 total_count=0
    today_epoch=$(date +%s)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((total_count++)) || true
        local entry_date
        entry_date=$(echo "$line" | sed -n 's/.*"date":"\([^"]*\)".*/\1/p')
        if [[ -n "$entry_date" ]]; then
            local entry_epoch
            entry_epoch=$(date -d "$entry_date" +%s 2>/dev/null || echo "0")
            local age_days=$(( (today_epoch - entry_epoch) / 86400 ))
            if [[ $age_days -gt $max_age ]]; then
                ((stale_count++)) || true
                local entry_title
                entry_title=$(echo "$line" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')
                echo "STALE ($age_days days): $entry_title"
            fi
        fi
    done < "$index"
    if [[ $stale_count -gt 0 ]]; then
        echo "$stale_count of $total_count entries are stale (>$max_age days)."
        return 1
    else
        echo "All $total_count entries are fresh (<=$max_age days)."
        return 0
    fi
}

# sync_index <index_file>
# Lists entries that should be verified against GitHub for reconciliation.
sync_index() {
    local index="$1"
    if [[ ! -f "$index" ]] || [[ ! -s "$index" ]]; then
        echo "No dedup index or empty — nothing to sync."
        return 0
    fi
    echo "Entries to verify against GitHub:"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local title number
        title=$(echo "$line" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')
        number=$(echo "$line" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
        echo "  #$number: $title"
    done < "$index"
    echo ""
    echo "Use GitHub MCP to check issue status, then remove closed entries manually."
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
    usage
fi

case "${1:-}" in
    --scrub)
        [[ $# -lt 2 ]] && { echo "Error: --scrub requires <body_file>" >&2; exit 1; }
        scrub_check "$2"
        ;;
    --dedup)
        [[ $# -lt 2 ]] && { echo "Error: --dedup requires <title>" >&2; exit 1; }
        dedup_check "$2" "${3:-$DEFAULT_INDEX}"
        ;;
    --record)
        [[ $# -lt 3 ]] && { echo "Error: --record requires <title> <issue_number>" >&2; exit 1; }
        record_issue "$2" "$3" "${4:-$DEFAULT_INDEX}"
        ;;
    --format)
        [[ $# -lt 5 ]] && { echo "Error: --format requires <title> <category> <severity> <body_file>" >&2; exit 1; }
        format_body "$2" "$3" "$4" "$5"
        ;;
    --check-stale)
        [[ $# -lt 2 ]] && { echo "Usage: --check-stale <index_file> [max_age_days]" >&2; exit 1; }
        check_stale "$2" "${3:-90}"
        ;;
    --sync-index)
        sync_index "${2:-$DEFAULT_INDEX}"
        ;;
    *)
        usage
        ;;
esac
