#!/usr/bin/env bash
# lib-dashboard.sh — helpers shared by the dashboard-cache writers (CFG-1093 P-SHUTDOWN).
# Sourced by lsd-refresh.sh, dashboard-row.sh (--auto) and session-close.sh. One summariser
# for every writer, so the row a session writes at shutdown and the row the next
# lsd-refresh computes cannot disagree. Library, not an afx verb (afx skips lib-*).

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

# A cache Path cell as a filesystem path: backticks stripped, a trailing ` (…)` annotation dropped
# (live cells look like `~/some-project (build/canonical)`), a leading ~ expanded.
dashboard_expand_path() {
    local p="${1//\`/}"
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ "$p" =~ ^(.*[^[:space:]])[[:space:]]+\([^()]*\)$ ]] && p="${BASH_REMATCH[1]}"
    printf '%s' "${p/#\~/$HOME}"
}

# dashboard_project_for_dir <cache> <dir> — prints the project whose Path cell is <dir>
# (compared after resolving both, so a trailing slash or symlink does not matter); 1 if none.
dashboard_project_for_dir() {
    local cache="$1" want line name path got
    want="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
    [[ -f "$cache" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == '| '* ]] || continue
        name="$(awk -F'|' '{v=$2; gsub(/^ +| +$/, "", v); print v}' <<<"$line")"
        path="$(awk -F'|' '{print $5}' <<<"$line")"
        [[ -z "$name" || "$name" == Project || "$name" == -* ]] && continue
        path="$(dashboard_expand_path "$path")"
        [[ -n "$path" && -d "$path" ]] || continue
        got="$(cd "$path" && pwd -P)"
        if [[ "$got" == "$want" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done < "$cache"
    return 1
}
