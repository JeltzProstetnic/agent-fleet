#!/usr/bin/env bash
# lsd-refresh.sh — Regenerate dashboard cache from backlogs and filesystem
# Usage: bash ~/agent-fleet/setup/scripts/lsd-refresh.sh
# Reads registry.md, scans local backlogs and disk sizes, writes dashboard-cache.md
# (Single-row updates at shutdown go through dashboard-row.sh, not this script.)

set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: keep '&' literal in ${v//x/y}

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
#    a project with no active session never noticed. (Observed 2026-08-25.)
# ⇒ Rule: a cell longer than PROSE_MIN characters is human prose and is NEVER overwritten by a
#    generated value. Short generated tokens (dates, counts) still refresh normally.
# ⇒ Rule (CFG-576): a project that is not on this machine keeps its whole previous row — a
#    refresh only rewrites what it can actually compute here.
# ⇒ Rule (CFG-576): the refresh's OWN long values are not prose. A joined P1 list or a done
#    line easily passes PROSE_MIN, and the refresh then froze its own output forever (closed
#    P1 items stayed listed). Every generated cell over PROSE_MIN is recorded in a comment
#    block after the table (GEN_MARK); a cell still equal to its record is regenerated.
# ⇒ Rule (CFG-576): that only works if the cell READ BACK equals what was recorded. A '|' in a
#    P1 name (the cfg backlog has "`|| true`") or a done line split the row, split_row folded
#    the fragments back with '; ', the read-back never matched, and the cell froze — mangled.
#    So every generated value is first put in the exact form it reads back as (clean_cell),
#    and the record is compared encoded to encoded (gen_key) and kept by byte length (byte_len).
PROSE_MIN=40
GEN_MARK='<!-- lsd-refresh generated cells'
NCOLS=10   # Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone

# --- Lock shared with dashboard-row.sh (CFG-576) -----------------------------
# ⛔ The refresh used to read the cache at START, spend seconds in `du`, then write the whole
#    file — reverting any row a session had updated in between. Now everything slow happens
#    first, and the read-merge-write of the cache happens under `<cache>.lock` (a directory:
#    mkdir is atomic everywhere and needs no flock), the same lock dashboard-row.sh takes.
LOCK="${CACHE}.lock"
LOCK_TIMEOUT="${DASHBOARD_LOCK_TIMEOUT:-10}"
LOCK_STALE="${DASHBOARD_LOCK_STALE:-60}"

mtime() {
    local t
    t=$(stat -c %Y "$1" 2>/dev/null) || t=$(stat -f %m "$1" 2>/dev/null) || t=""
    [[ "$t" =~ ^[0-9]+$ ]] || t=$(date +%s)
    printf '%s' "$t"
}

lock_acquire() {
    local tries=0 max=$(( LOCK_TIMEOUT * 10 ))
    until mkdir "$LOCK" 2>/dev/null; do
        if (( $(date +%s) - $(mtime "$LOCK") > LOCK_STALE )); then
            echo "lsd-refresh: breaking stale lock $LOCK" >&2
            rmdir "$LOCK" 2>/dev/null || true
            continue
        fi
        if (( tries >= max )); then
            echo "ERROR: timed out after ${LOCK_TIMEOUT}s waiting for $LOCK — cache not written" >&2
            return 1
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
}

# Split a cache row into exactly NCOLS trimmed cells (global array `cells`); same repair
# rules as dashboard-row.sh — pad a short row, fold pipe-split P1Names back into one cell.
split_row() {
    local body="${1#|}"
    [[ "$body" == *'|' ]] && body="${body%|}"
    local -a raw=()
    IFS='|' read -r -a raw <<<"$body"
    local i v n=${#raw[@]}
    for ((i = 0; i < n; i++)); do
        v="${raw[i]}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        raw[i]="$v"
    done
    cells=()
    if (( n > NCOLS )); then
        cells=("${raw[@]:0:8}")
        local joined="" part
        for part in "${raw[@]:8:n-9}"; do
            [[ -z "$part" ]] && continue
            joined="${joined:+$joined; }$part"
        done
        cells+=("$joined" "${raw[n-1]}")
    else
        cells=("${raw[@]}")
        while (( ${#cells[@]} < NCOLS )); do cells+=(""); done
    fi
}

# A generated value in exactly the form split_row reads it back as (global `cleaned`): no '|' —
# the separator every reader splits on; '; ' instead, as dashboard-row.sh's clean_value — no CR
# or newline (a CRLF backlog), and no surrounding whitespace (a trailing markdown line break).
clean_cell() {
    local v="$1"
    v="${v//$'\r'/}"
    v="${v//$'\n'/ }"
    v="${v//|/; }"
    while [[ "$v" == *';  '* ]]; do v="${v//;  /; }"; done
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    cleaned="$v"
}

# A cell as it is stored in the record block (global `key`). The block is an HTML comment, so a
# '-->' in a value would close it early: '&' and '>' are entity-encoded. Compare key to key.
gen_key() {
    local v="${1//&/&amp;}"
    key="${v//>/&gt;}"
}

# Length in bytes (global `blen`) — never less than the character count in any locale, so a
# cell recorded by a UTF-8 run is still recognised by a C-locale run that counts '—' as 3.
byte_len() {
    local LC_ALL=C
    blen=${#1}
}

# Summarise one backlog. Prints four lines: tasks, deadline, p1names, lastdone.
# ⛔ The counter used to read only a `## Open` section (and `## Open questions` matched too),
#    count every line carrying a `[Pn]` tag — done ones included — and file everything else,
#    P0 included, under P3. A track-sectioned backlog with `(P1)` tags came out as `1P3`.
# ⇒ Open = a top-level `- [ ]`, `- [>]` or `- [?]` item anywhere outside a `## Done` section.
#    Priority = the item's first `[Pn]` or `(Pn…` tag. Untagged items default to P3 per the
#    backlog convention — unless NOTHING is tagged, in which case a priority split would be
#    invented, so the cell says `N open` instead.
summarise_backlog() {
    awk '
        /^## / { in_done = ($0 ~ /^## Done/); next }
        in_done {
            if (last_done == "" && $0 ~ /^- \[x\] /) { last_done = substr($0, 7) }
            next
        }
        /^- \[[ >?]\] / {
            total++
            line = $0
            if (match(line, /[[(]P[0-5][]) ,:]/)) {
                p = substr(line, RSTART + 2, 1)
                cnt[p]++; tagged++
                if (p == "1" && match(line, /\*\*[^*]+\*\*/)) {
                    name = substr(line, RSTART + 2, RLENGTH - 4)
                    sub(/: *$/, "", name)
                    names = (names == "" ? name : names "; " name)
                }
            }
            if (deadline == "" && match(line, /(deadline|due|by [A-Z][a-z]+ [0-9]+|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9]+ days)/)) {
                deadline = substr(line, RSTART, RLENGTH)
            }
        }
        END {
            tasks = ""
            if (total > 0 && tagged == 0) {
                tasks = total " open"
            } else if (total > 0) {
                cnt["3"] += total - tagged
                for (p = 0; p <= 5; p++) if (cnt[p] > 0) tasks = tasks (tasks == "" ? "" : " ") cnt[p] "P" p
            }
            if (tasks == "") tasks = "—"
            if (total > 0) last_done = ""
            print tasks; print deadline; print names; print last_done
        }
    ' "$1"
}

# --- Phase 1: compute (slow — du, backlog scans — and done WITHOUT the lock) --
r_project=() r_pnum=() r_parent=() r_path=() r_type=() r_local=()
r_tasks=() r_size=() r_deadline=() r_p1=() r_last=()

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
        { IFS= read -r task_counts; IFS= read -r deadline; IFS= read -r p1_names; IFS= read -r last_done; } \
            < <(summarise_backlog "${path_expanded}/backlog.md")
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

    r_project+=("$project"); r_pnum+=("$pnum"); r_parent+=("$parent_display")
    r_path+=("$path_clean"); r_type+=("$type_display"); r_local+=("$is_local")
    clean_cell "$task_counts"; r_tasks+=("$cleaned")
    clean_cell "$disk_size";   r_size+=("$cleaned")
    clean_cell "$deadline";    r_deadline+=("$cleaned")
    clean_cell "$p1_names";    r_p1+=("$cleaned")
    clean_cell "$last_done";   r_last+=("$cleaned")

done < "$REGISTRY"

# --- Phase 2: merge with the cache as it is NOW, under the lock --------------
mkdir -p "$(dirname "$CACHE")"   # the lock lives next to the cache
lock_acquire || exit 1
TMP=""
trap 'rm -f "$TMP"; rmdir "$LOCK" 2>/dev/null || true' EXIT

declare -A prev_cell prev_row prev_gen
if [[ -f "$CACHE" ]]; then
    cp "$CACHE" "${CACHE}.bak"
    # Records of the long cells the last refresh generated: "<project>\t<col>\t<value>".
    in_gen=false
    while IFS= read -r prev_line; do
        if [[ "$prev_line" == "$GEN_MARK"* ]]; then in_gen=true; continue; fi
        $in_gen || continue
        [[ "$prev_line" == '-->'* ]] && break
        IFS=$'\t' read -r g_proj g_col g_val <<<"$prev_line" || true
        [[ -n "$g_proj" && "$g_col" =~ ^[789]$ ]] && prev_gen["${g_proj}:${g_col}"]="$g_val"
    done < "$CACHE"
    while IFS= read -r prev_line; do
        [[ "$prev_line" =~ ^\| ]] || continue
        [[ "$prev_line" =~ ^\|\ Project\ \| ]] && continue
        [[ "$prev_line" =~ ^\|[-\ |]+\|$ ]] && continue
        split_row "$prev_line"
        pname="${cells[0]}"
        [[ -z "$pname" ]] && continue
        prev_row["$pname"]=1
        for col in 5 6 7 8 9; do
            prev_cell["${pname}:all:${col}"]="${cells[col]}"
        done
        for col in 7 8 9; do
            gen_key "${cells[col]}"
            if (( ${#cells[col]} > PROSE_MIN )) && [[ "$key" != "${prev_gen["${pname}:${col}"]:-}" ]]; then
                prev_cell["${pname}:${col}"]="${cells[col]}"
            fi
        done
        # ⚠ Tasks is a COMPUTED column, but some sessions hand-write a richer count there
        #   (`80 open, 33 in progress / 78 done`). Keep a hand-written value, and only refresh
        #   one that looks generated.
        tasks_val="${cells[5]}"
        if [[ -n "$tasks_val" && ! "$tasks_val" =~ ^(—|[0-9]+\ open|([0-9]+P[0-9])( [0-9]+P[0-9])*)$ ]]; then
            prev_cell["${pname}:5"]="$tasks_val"
        fi
    done < "$CACHE"
fi

rows=()
gen_records=()
for i in "${!r_project[@]}"; do
    project="${r_project[i]}"
    vals=("${r_tasks[i]}" "${r_size[i]}" "${r_deadline[i]}" "${r_p1[i]}" "${r_last[i]}")
    for col in 5 6 7 8 9; do
        generated=true
        if [[ "${r_local[i]}" != true && -n "${prev_row[$project]:-}" ]]; then
            # Not on this machine: nothing here is computed, so the previous row stands —
            # and so does its generated record, or the owning machine would freeze the cell.
            vals[col - 5]="${prev_cell["${project}:all:${col}"]}"
            gen_key "${vals[col - 5]}"
            [[ "$key" == "${prev_gen["${project}:${col}"]:-}" ]] || generated=false
        elif [[ -n "${prev_cell["${project}:${col}"]:-}" ]]; then
            # Human prose / hand-written count wins over anything generated for it.
            vals[col - 5]="${prev_cell["${project}:${col}"]}"
            generated=false
        fi
        v="${vals[col - 5]}"
        if (( col >= 7 )) && $generated; then
            byte_len "$v"
            if (( blen > PROSE_MIN )); then
                gen_key "$v"
                gen_records+=("${project}"$'\t'"${col}"$'\t'"${key}")
            fi
        fi
    done
    rows+=("| ${project} | P${r_pnum[i]} | ${r_parent[i]} | ${r_path[i]} | ${r_type[i]} | ${vals[0]} | ${vals[1]} | ${vals[2]} | ${vals[3]} | ${vals[4]} |")
done

# Write cache file — to a temp file, then one atomic rename.
TMP=$(mktemp "${CACHE}.XXXXXX")
[[ -f "$CACHE" ]] && cp -p "$CACHE" "$TMP"   # carries the file mode across the rename
cat > "$TMP" << EOF
# Dashboard Cache

Last refreshed: $(date -u '+%Y-%m-%d %H:%M UTC') on ${HOSTNAME_SHORT}

Generated by \`setup/scripts/lsd-refresh.sh\`, which refreshes the COMPUTED columns
(Priority, Parent, Path, Type, Tasks, Size) on every run — for projects present on the
refreshing machine only; every other project keeps its previous row.

The **Deadline / P1Names / LastDone** cells are the project sessions' own — the shutdown
checklist tells each project to keep its row's state snapshot current there, via
\`setup/scripts/dashboard-row.sh\` (never a hand edit of this file). Any such cell
longer than 40 characters is treated as human prose and is **never** overwritten by a refresh —
except the refresh's own long values, recorded in the comment block below the table.
Previous cache is kept at \`dashboard-cache.md.bak\`.

| Project | Priority | Parent | Path | Type | Tasks | Size | Deadline | P1Names | LastDone |
|---------|----------|--------|------|------|-------|------|----------|---------|----------|
EOF

for row in "${rows[@]}"; do
    echo "$row" >> "$TMP"
done
if (( ${#gen_records[@]} > 0 )); then
    {
        printf '\n%s (CFG-576): a cell over 40 chars that still equals its record here is the\n' "$GEN_MARK"
        printf "refresh's own output and is regenerated on the next run, not kept as prose. Do not edit.\n"
        printf '%s\n' "${gen_records[@]}"
        printf -- '-->\n'
    } >> "$TMP"
fi
mv -f "$TMP" "$CACHE"
TMP=""

echo "Dashboard cache updated: ${#rows[@]} projects written to ${CACHE}"
