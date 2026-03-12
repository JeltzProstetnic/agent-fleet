#!/usr/bin/env bash
# youtube-tabs.sh — Save/restore YouTube tabs from Chrome sessions across machines
# Usage: youtube-tabs.sh save|list|open [query]
#
# Environment overrides (for testing):
#   YOUTUBE_TABS_FILE   — path to JSON storage file
#   CHROME_SESSIONS_DIR — path to Chrome Sessions directory
#   MACHINE_NAME        — override machine hostname
#   DRY_RUN=1           — print URLs instead of opening browser

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TABS_FILE="${YOUTUBE_TABS_FILE:-$REPO_ROOT/cross-project/youtube-tabs.json}"
MACHINE="${MACHINE_NAME:-$(cat /etc/hostname 2>/dev/null || echo "unknown")}"

# ── Find Chrome Sessions directory ──────────────────────────────────────────

find_chrome_sessions() {
    if [[ -n "${CHROME_SESSIONS_DIR:-}" ]]; then
        if [[ -d "$CHROME_SESSIONS_DIR" ]]; then
            echo "$CHROME_SESSIONS_DIR"
            return 0
        else
            echo "Error: Sessions directory not found: $CHROME_SESSIONS_DIR" >&2
            return 1
        fi
    fi

    # WSL — Chrome on Windows side
    if [[ -d "/mnt/c" ]]; then
        for d in /mnt/c/Users/*/AppData/Local/Google/Chrome/User\ Data/Default/Sessions; do
            if [[ -d "$d" ]]; then
                echo "$d"
                return 0
            fi
        done
    fi

    # Native Linux (Fedora, Steam Deck)
    for d in "$HOME/.config/google-chrome/Default/Sessions" \
             "$HOME/.config/chromium/Default/Sessions"; do
        if [[ -d "$d" ]]; then
            echo "$d"
            return 0
        fi
    done

    echo "Error: Chrome sessions directory not found" >&2
    return 1
}

# ── Extract YouTube tabs from session files ─────────────────────────────────

extract_youtube_tabs() {
    local sessions_dir="$1"

    # Chrome rotates session files. Only the most recent non-empty file
    # has the current tab state. Sort by filename descending (higher
    # timestamp = newer), use the first one that contains YouTube data.
    local target_file=""
    # Session_* files have the live tab state; Tabs_* can lag behind.
    # Try Session files first (newest to oldest), then Tabs as fallback.
    local candidates=()
    for f in "$sessions_dir"/Session_*; do
        [[ -f "$f" ]] || continue
        candidates+=("$f")
    done
    IFS=$'\n' candidates=($(printf '%s\n' "${candidates[@]}" | sort -r))
    unset IFS

    for f in "${candidates[@]}"; do
        local hits
        hits=$(strings -el "$f" 2>/dev/null | grep -ci 'youtube.com/watch\|youtube.com/shorts' || true)
        if [[ "$hits" -gt 0 ]]; then
            target_file="$f"
            break
        fi
    done

    # Fallback to Tabs_* if no Session file has YouTube data
    if [[ -z "$target_file" ]]; then
        candidates=()
        for f in "$sessions_dir"/Tabs_*; do
            [[ -f "$f" ]] || continue
            candidates+=("$f")
        done
        IFS=$'\n' candidates=($(printf '%s\n' "${candidates[@]}" | sort -r))
        unset IFS
        for f in "${candidates[@]}"; do
            local hits
            hits=$(strings -el "$f" 2>/dev/null | grep -ci 'youtube.com/watch\|youtube.com/shorts' || true)
            if [[ "$hits" -gt 0 ]]; then
                target_file="$f"
                break
            fi
        done
    fi

    if [[ -z "$target_file" ]]; then
        return 0
    fi

    # Chrome SNSS format stores titles + URLs as UTF-16LE strings
    # Pattern: "Title - YouTube" followed by the watch URL
    (strings -el "$target_file" 2>/dev/null || true) | python3 -c "
import sys, re

title_pattern = re.compile(r'^(.+) - YouTube$')
url_pattern = re.compile(r'^https://(?:www\.)?youtube\.com/(watch\?|shorts/)')
# Skip noise URLs
skip_pattern = re.compile(r'(studio\.youtube|persist_identity|embed/|/api/|/s/)')

pending_title = None
seen_urls = set()
results = []

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue

    m = title_pattern.match(line)
    if m:
        pending_title = m.group(1)
        continue

    if url_pattern.match(line) and not skip_pattern.search(line):
        # Normalize: strip tracking params after &pp=
        clean_url = re.sub(r'&pp=.*$', '', line)
        if clean_url not in seen_urls:
            seen_urls.add(clean_url)
            title = pending_title if pending_title else ''
            print(f'{title}\t{clean_url}')
        pending_title = None
    else:
        pending_title = None
"
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_save() {
    local sessions_dir
    sessions_dir=$(find_chrome_sessions) || return 1

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local raw_tabs
    raw_tabs=$(extract_youtube_tabs "$sessions_dir")

    if [[ -z "$raw_tabs" ]]; then
        echo "No YouTube tabs found in Chrome sessions."
        return 0
    fi

    # Build new JSON, merging with existing file (keep other machines' tabs)
    YT_TABS_FILE="$TABS_FILE" YT_MACHINE="$MACHINE" YT_NOW="$now" \
    python3 -c '
import json, sys, os

tabs_file = os.environ["YT_TABS_FILE"]
machine = os.environ["YT_MACHINE"]
now = os.environ["YT_NOW"]

# Read existing
existing = {"tabs": []}
if os.path.exists(tabs_file):
    try:
        with open(tabs_file) as f:
            existing = json.load(f)
    except (json.JSONDecodeError, IOError):
        pass

# Keep tabs from OTHER machines
other_tabs = [t for t in existing.get("tabs", []) if t.get("machine") != machine]

# Parse new tabs from stdin
new_tabs = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split("\t", 1)
    if len(parts) == 2:
        title, url = parts
    else:
        title, url = "", parts[0]
    new_tabs.append({
        "url": url,
        "title": title,
        "machine": machine,
        "saved_at": now
    })

result = {"tabs": other_tabs + new_tabs}

os.makedirs(os.path.dirname(tabs_file), exist_ok=True)
with open(tabs_file, "w") as f:
    json.dump(result, f, indent=2)

print(f"Saved {len(new_tabs)} YouTube tab(s) from {machine}")
if other_tabs:
    print(f"Kept {len(other_tabs)} tab(s) from other machines")
' <<< "$raw_tabs"
}

cmd_list() {
    local query="${1:-}"

    if [[ ! -f "$TABS_FILE" ]]; then
        echo "No saved tabs. Run 'youtube-tabs.sh save' first."
        return 0
    fi

    YT_QUERY="$query" YT_TABS_FILE="$TABS_FILE" \
    python3 -c '
import json, sys, os

query = os.environ.get("YT_QUERY", "").lower()
tabs_file = os.environ["YT_TABS_FILE"]

with open(tabs_file) as f:
    data = json.load(f)

tabs = data.get("tabs", [])
if not tabs:
    print("No saved tabs.")
    sys.exit(0)

matched = []
for t in tabs:
    searchable = (t.get("title", "") + " " + t.get("url", "")).lower()
    if not query or query in searchable:
        matched.append(t)

if not matched:
    print(f"No tabs matching \"{query}\".")
    sys.exit(0)

# Group by machine
machines = {}
for t in matched:
    m = t.get("machine", "unknown")
    machines.setdefault(m, []).append(t)

for machine, mtabs in machines.items():
    print(f"\n  {machine} ({len(mtabs)} tab(s)):")
    for t in mtabs:
        title = t.get("title") or "(no title)"
        url = t["url"]
        print(f"    {title}")
        print(f"    {url}")
        print()
'
}

cmd_open() {
    local query="${1:-}"

    if [[ -z "$query" ]]; then
        echo "Usage: youtube-tabs.sh open <query>" >&2
        return 1
    fi

    if [[ ! -f "$TABS_FILE" ]]; then
        echo "No saved tabs. Run 'youtube-tabs.sh save' first." >&2
        return 1
    fi

    local url
    url=$(YT_QUERY="$query" YT_TABS_FILE="$TABS_FILE" \
    python3 -c '
import json, sys, os

query = os.environ["YT_QUERY"].lower()
tabs_file = os.environ["YT_TABS_FILE"]

with open(tabs_file) as f:
    data = json.load(f)

for t in data.get("tabs", []):
    searchable = (t.get("title", "") + " " + t.get("url", "")).lower()
    if query in searchable:
        print(t["url"])
        sys.exit(0)

print("NO_MATCH", file=sys.stderr)
sys.exit(1)
' 2>&1) || true

    if [[ "$url" == *"NO_MATCH"* ]] || [[ -z "$url" ]]; then
        echo "No matching tab for \"$query\"." >&2
        return 1
    fi

    if [[ "${DRY_RUN:-}" == "1" ]]; then
        echo "$url"
        return 0
    fi

    # Open in browser
    if [[ -d "/mnt/c" ]]; then
        # WSL — use PowerShell to open in Windows browser
        powershell.exe -Command "Start-Process '$url'" 2>/dev/null
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url" 2>/dev/null
    else
        echo "$url"
        echo "(Could not detect browser — URL printed above)"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    save)  cmd_save ;;
    list)  cmd_list "${2:-}" ;;
    open)  cmd_open "${2:-}" ;;
    *)
        echo "Usage: youtube-tabs.sh save|list|open [query]"
        echo ""
        echo "Commands:"
        echo "  save          Collect open YouTube tabs from Chrome"
        echo "  list [query]  Show saved tabs (optional filter)"
        echo "  open <query>  Open matching tab in browser"
        exit 1
        ;;
esac
