#!/usr/bin/env bash
# lsd-refresh.sh — Regenerate dashboard cache from backlogs and filesystem
# Usage: bash ~/agent-fleet/setup/scripts/lsd-refresh.sh
# Reads registry.md, scans local backlogs and disk sizes, writes dashboard-cache.md

set -euo pipefail

REGISTRY="${HOME}/agent-fleet/registry.md"
CACHE="${HOME}/agent-fleet/cross-project/dashboard-cache.md"
HOSTNAME_SHORT=$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo "unknown")

if [[ ! -f "$REGISTRY" ]]; then
    echo "ERROR: Registry not found at $REGISTRY"
    exit 1
fi

# --- Preserve human-written cells, and keep one restore point ----------------
# ⛔ This script used to overwrite the cache wholesale. The shutdown checklist tells every
#    project to keep its own row's state snapshot current, and that prose lives ONLY in the
#    working tree until someone commits the cache — so a refresh silently destroyed it, and
#    a project with no active session never noticed. (crucible, 2026-08-25.)
# ⇒ Rule: a cell longer than PROSE_MIN characters is human prose and is NEVER overwritten by a
#    generated value. Short generated tokens (dates, counts) still refresh normally.
PROSE_MIN=40
declare -A prev_cell
if [[ -f "$CACHE" ]]; then
    cp "$CACHE" "${CACHE}.bak"
    while IFS= read -r prev_line; do
        [[ "$prev_line" =~ ^\| ]] || continue
        [[ "$prev_line" =~ ^\|\ Project\ \| ]] && continue
        [[ "$prev_line" =~ ^\|[-\ |]+\|$ ]] && continue
        pname=$(awk -F'|' '{print $2}' <<<"$prev_line" | xargs)
        [[ -z "$pname" ]] && continue
        for col in 9 10 11; do
            val=$(awk -F'|' -v c="$col" '{print $c}' <<<"$prev_line" | sed 's/^ *//; s/ *$//')
            if (( ${#val} > PROSE_MIN )); then
                prev_cell["${pname}:${col}"]="$val"
            fi
        done
        # ⚠ Tasks (col 7) is a COMPUTED column, but the generator only understands `[P1]`-style
        #   tags and a `## Open` section. Backlogs written any other way collapse to a useless
        #   `1P3`, and some sessions have hand-written a real count there instead. So: keep a
        #   hand-written value, and only refresh one that already looks generated.
        tasks_val=$(awk -F'|' '{print $7}' <<<"$prev_line" | sed 's/^ *//; s/ *$//')
        if [[ -n "$tasks_val" && ! "$tasks_val" =~ ^(—|([0-9]+P[0-9])( [0-9]+P[0-9])*)$ ]]; then
            prev_cell["${pname}:7"]="$tasks_val"
        fi
    done < "$CACHE"
fi

# Collect rows
rows=()

in_projects_table=false
header_seen=false

while IFS= read -r line; do
    # Detect start of Projects table
    if [[ "$line" =~ ^\|\ Project\ \|\ Priority ]]; then
        in_projects_table=true
        header_seen=false
        continue
    fi

    # Skip separator line
    if $in_projects_table && [[ "$line" =~ ^\|[-\ |]+\|$ ]]; then
        header_seen=true
        continue
    fi

    # Stop at next heading or non-table line after table started
    if $in_projects_table && $header_seen; then
        if [[ ! "$line" =~ ^\| ]]; then
            break
        fi
    fi

    if ! $in_projects_table || ! $header_seen; then
        continue
    fi

    # Parse table row — split by |
    project=$(echo "$line" | awk -F'|' '{print $2}' | xargs)
    priority=$(echo "$line" | awk -F'|' '{print $3}' | xargs)
    parent=$(echo "$line" | awk -F'|' '{print $4}' | xargs)
    path_raw=$(echo "$line" | awk -F'|' '{print $5}' | xargs)
    github=$(echo "$line" | awk -F'|' '{print $6}' | xargs)
    type_val=$(echo "$line" | awk -F'|' '{print $8}' | xargs)

    # Skip empty rows
    [[ -z "$project" ]] && continue

    # Extract priority number
    pnum="${priority//[^0-9]/}"
    [[ -z "$pnum" ]] && continue

    # Resolve path (strip backticks, expand ~)
    path_clean="${path_raw//\`/}"
    path_expanded="${path_clean/#\~/$HOME}"

    # Check if local
    is_local=false
    [[ -d "$path_expanded" ]] && is_local=true

    # Disk size
    disk_size="—"
    if $is_local; then
        disk_size=$(du -sh "$path_expanded" 2>/dev/null | awk '{print $1}')
    fi

    # Task counts from backlog
    task_counts="—"
    deadline=""
    p1_names=""
    last_done=""
    if $is_local && [[ -f "${path_expanded}/backlog.md" ]]; then
        backlog="${path_expanded}/backlog.md"

        # Extract only the Open section
        open_section=$(sed -n '/^## Open/,/^## Done\|^## /{ /^## Open/d; /^## Done/d; /^## /d; p; }' "$backlog")

        if [[ -n "$open_section" ]]; then
            p1=$(echo "$open_section" | grep -c '\[P1\]' 2>/dev/null || true)
            p2=$(echo "$open_section" | grep -c '\[P2\]' 2>/dev/null || true)
            p3_tagged=$(echo "$open_section" | grep -c '\[P3\]' 2>/dev/null || true)
            p4=$(echo "$open_section" | grep -c '\[P4\]' 2>/dev/null || true)
            p5=$(echo "$open_section" | grep -c '\[P5\]' 2>/dev/null || true)
            total_open=$(echo "$open_section" | grep -c '^- \[ \]' 2>/dev/null || true)
            tagged=$((p1 + p2 + p3_tagged + p4 + p5))
            untagged=$((total_open - tagged))
            p3=$((p3_tagged + untagged))

            parts=()
            (( p1 > 0 )) && parts+=("${p1}P1")
            (( p2 > 0 )) && parts+=("${p2}P2")
            (( p3 > 0 )) && parts+=("${p3}P3")
            (( p4 > 0 )) && parts+=("${p4}P4")
            (( p5 > 0 )) && parts+=("${p5}P5")

            if (( ${#parts[@]} > 0 )); then
                task_counts=$(IFS=' '; echo "${parts[*]}")
            fi

            # Extract P1 task names (bold title between ** **)
            if (( p1 > 0 )); then
                p1_names=$(echo "$open_section" | grep '\[P1\]' | sed -n 's/.*\*\*\([^*]*\)\*\*.*/\1/p' | sed 's/: *$//' | paste -sd '|' -)
            fi

            # Check for deadlines
            deadline=$(echo "$open_section" | grep -iEo '(deadline|due|by [A-Z][a-z]+ [0-9]+|[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]+ days)' 2>/dev/null | head -1 || true)
        else
            # No open tasks — extract last completed item from Done section
            last_done=$(sed -n '/^## Done/,$ p' "$backlog" | grep '^\- \[x\]' | head -1 | sed 's/^- \[x\] //' || true)
        fi
    fi

    # Type indicators — only append if not already in type_val
    type_display="$type_val"
    if [[ "$github" == *"dual push"* && "$type_val" != *"(d)"* ]]; then
        type_display="${type_val} (d)"
    elif [[ "$github" == *"public"* && "$github" == *"private"* && "$type_val" != *"(p)"* ]]; then
        type_display="${type_val} (p)"
    fi

    # Parent display
    parent_display="${parent}"
    [[ "$parent" == "—" || -z "$parent" ]] && parent_display="—"

    # Human prose in a cell wins over anything generated for it (see PROSE_MIN above).
    if [[ -n "${prev_cell["${project}:7"]:-}" ]]; then
        task_counts="${prev_cell["${project}:7"]}"
    fi
    if [[ -n "${prev_cell["${project}:9"]:-}" ]]; then
        deadline="${prev_cell["${project}:9"]}"
    fi
    if [[ -n "${prev_cell["${project}:10"]:-}" ]]; then
        p1_names="${prev_cell["${project}:10"]}"
    fi
    if [[ -n "${prev_cell["${project}:11"]:-}" ]]; then
        last_done="${prev_cell["${project}:11"]}"
    fi

    rows+=("| ${project} | P${pnum} | ${parent_display} | ${path_clean} | ${type_display} | ${task_counts} | ${disk_size} | ${deadline} | ${p1_names} | ${last_done} |")

done < "$REGISTRY"

# Write cache file
cat > "$CACHE" << EOF
# Dashboard Cache

Last refreshed: $(date -u '+%Y-%m-%d %H:%M UTC') on ${HOSTNAME_SHORT}

Generated by \`setup/scripts/lsd-refresh.sh\`, which refreshes the COMPUTED columns
(Priority, Parent, Path, Type, Tasks, Size) on every run.

The **Deadline / P1Names / LastDone** cells are the project sessions' own — the shutdown
checklist tells each project to keep its row's state snapshot current there. Any such cell
longer than 40 characters is treated as human prose and is **never** overwritten by a refresh.
Previous cache is kept at \`dashboard-cache.md.bak\`.

| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
EOF

for row in "${rows[@]}"; do
    echo "$row" >> "$CACHE"
done

echo "Dashboard cache updated: ${#rows[@]} projects written to ${CACHE}"
