#!/usr/bin/env bash
# sync-lib/common.sh — Shared utility functions for sync.sh modules
#
# Expects these variables from the caller:
#   SCRIPT_DIR, GLOBAL_DIR, PROJECTS_DIR, CLAUDE_HOME, PLATFORM
#   RED, GREEN, YELLOW, NC
#   log_info, log_warn, log_error (functions)

# Source portable wrappers (_sed_i, _readlink_f, etc.)
source "${GLOBAL_DIR:-$SCRIPT_DIR/global}/hooks/lib-portable.sh" 2>/dev/null || true

# cc-mirror root (Claude Code installed via cc-mirror)
CC_MIRROR_DIR="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"

# ---- Portable hostname (SteamOS has no hostname binary) ----
get_hostname() {
    hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown"
}

# ---- Find project path by name ----
find_project_path() {
    local name="$1"
    # Check common locations
    for candidate in "$HOME/$name" "$HOME/projects/$name"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    # Check registry for custom paths.
    # The Path column index is NOT hardcoded — it is located by header name so
    # the parse survives column-layout changes (e.g. CFG: a "Parent" column was
    # inserted before "Path", which previously shifted the value out of $4).
    if [ -f "$SCRIPT_DIR/registry.md" ]; then
        local path
        path=$(awk -F'|' -v name=" $name " '
            # Locate the Path column from the first header row that has one.
            path_col == 0 && $0 ~ /\| *Path *\|/ {
                for (i = 1; i <= NF; i++) {
                    g = $i; gsub(/^[ \t]+|[ \t]+$/, "", g)
                    if (g == "Path") { path_col = i; break }
                }
                next
            }
            # Match the data row whose first cell equals the project name.
            path_col > 0 {
                c2 = $2; gsub(/^[ \t]+|[ \t]+$/, "", c2)
                if (c2 == name_trimmed) {
                    v = $path_col
                    gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/`/, "", v)
                    print v
                    exit
                }
            }
            BEGIN { name_trimmed = name; gsub(/^[ \t]+|[ \t]+$/, "", name_trimmed) }
        ' "$SCRIPT_DIR/registry.md" 2>/dev/null)
        if [ -n "$path" ]; then
            path="${path/#\~/$HOME}"
            if [ -d "$path" ]; then
                echo "$path"
            fi
        fi
    fi
}

# ---- Extract file paths from a named manifest section ----
# Usage: _extract_manifest_section "Must Be Identical" "$manifest_file"
# Returns one file path per line (no hash — v1.0 manifest has no hash column)
_extract_manifest_section() {
    local section_name="$1"
    local manifest_file="$2"
    awk -v section="$section_name" '
        $0 ~ "## Tracked Files.*" section { in_section=1; next }
        /^## / && in_section { in_section=0 }
        in_section && /^\| `[^`]+`/ {
            match($0, /`[^`]+`/)
            if (RSTART > 0) {
                s = substr($0, RSTART+1, RLENGTH-2)
                print s
            }
        }
    ' "$manifest_file" || true
}

# ---- Portable symlink helpers (CFG-335: Windows/MINGW64 compatibility) ----
# On MINGW64 without Developer Mode, `ln -s` silently copies instead of creating
# real symlinks. These helpers detect that and fall back to cp accordingly.
# Verification checks adapt: _check_linked accepts copies on copy-mode platforms.

_SYMLINK_MODE=""  # "symlink" or "copy" — cached after first test

_can_symlink() {
    if [[ -n "$_SYMLINK_MODE" ]]; then
        [[ "$_SYMLINK_MODE" == "symlink" ]]
        return
    fi
    if [[ "${PLATFORM:-}" == "windows" ]]; then
        # Test actual symlink capability (Developer Mode may enable it)
        local test_dir
        test_dir=$(mktemp -d)
        echo "test" > "$test_dir/src"
        ln -s "$test_dir/src" "$test_dir/link" 2>/dev/null || true
        if [ -L "$test_dir/link" ]; then
            _SYMLINK_MODE="symlink"
        else
            _SYMLINK_MODE="copy"
        fi
        rm -rf "$test_dir"
    else
        _SYMLINK_MODE="symlink"
    fi
    [[ "$_SYMLINK_MODE" == "symlink" ]]
}

# _link_file <source> <target> — symlink or copy a file
_link_file() {
    local src="$1" dst="$2"
    if _can_symlink; then
        ln -sf "$src" "$dst"
    else
        cp -f "$src" "$dst"
    fi
}

# _link_dir <source> <target> — symlink or copy a directory
_link_dir() {
    local src="$1" dst="$2"
    if _can_symlink; then
        ln -sfn "$src" "$dst"
    else
        rm -rf "$dst"
        cp -rf "$src" "$dst"
    fi
}

# _check_linked <path> — true if path is a symlink (or exists in copy mode)
_check_linked() {
    local path="$1"
    if _can_symlink; then
        [ -L "$path" ]
    else
        [ -e "$path" ]
    fi
}

# _check_linked_valid <path> — true if symlink target exists (or file exists in copy mode)
_check_linked_valid() {
    local path="$1"
    if _can_symlink; then
        [ -L "$path" ] && [ -e "$path" ]
    else
        [ -e "$path" ]
    fi
}

# ---- Detect machine overlay directory name (CFG-296, data-driven CFG-700) ----
# Precedence: MACHINE_OVERRIDE="host:user" (test input, resolved through the map)
#   → FLEET_MACHINE (names the overlay directly) → setup/config/machines/machine-map.conf
#   → local_machine_map <host> <user> (optional, from sync.local.sh) → "".
# Map lines: <host-glob>[:<user>] <overlay>; first match wins; '#' starts a comment.
# Not SCHED_MACHINE: that is the overlay's OUTPUT, and plain-shell callers never see it.
detect_machine_dir() {
    local host user
    if [[ -n "${MACHINE_OVERRIDE:-}" ]]; then
        host="${MACHINE_OVERRIDE%%:*}"
        user="${MACHINE_OVERRIDE#*:}"
    elif [[ -n "${FLEET_MACHINE:-}" ]]; then
        echo "$FLEET_MACHINE"
        return 0
    else
        host=$(get_hostname)
        user=$(whoami 2>/dev/null || echo "${USER:-unknown}")
    fi

    local map="$SCRIPT_DIR/setup/config/machines/machine-map.conf"
    if [[ -f "$map" ]]; then
        local line key overlay hpat upat
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            read -r key overlay _ <<< "$line"
            [[ -z "$key" || -z "$overlay" ]] && continue
            hpat="${key%%:*}"
            upat=""
            [[ "$key" == *:* ]] && upat="${key#*:}"
            # shellcheck disable=SC2053  # unquoted RHS = glob match, by design
            if [[ "$host" == $hpat ]] && { [[ -z "$upat" ]] || [[ "$user" == $upat ]]; }; then
                echo "$overlay"
                return 0
            fi
        done < "$map"
    fi

    if type local_machine_map &>/dev/null; then
        local_machine_map "$host" "$user"
        return 0
    fi
    echo ""
}

# ---- Resolve config file with machine overlay (CFG-296) ----
# Returns machine overlay path if it exists, else base path, else empty.
resolve_config_file() {
    local filename="$1"
    local machine_dir
    machine_dir=$(detect_machine_dir)
    local overlay="$SCRIPT_DIR/setup/config/machines/$machine_dir/$filename"
    local base="$SCRIPT_DIR/setup/config/$filename"
    if [[ -n "$machine_dir" && -f "$overlay" ]]; then
        echo "$overlay"
    elif [[ -f "$base" ]]; then
        echo "$base"
    fi
}
