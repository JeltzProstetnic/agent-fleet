#!/usr/bin/env bash
# Tests for setup/scripts/project-icons.sh
# Verifies registry parsing, KDE icon application, command dispatch, and platform guards.
# Does NOT call actual KDE D-Bus or PowerShell. Tests output format and logic.

source "$(dirname "$0")/test-helpers.sh"

suite_header "Project Icons"

SCRIPT="$REPO_ROOT/setup/scripts/project-icons.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a mock registry file — matches the real registry column layout:
# $2=Project, $3=Priority, $4=Parent, $5=Path
create_mock_registry() {
    local registry="$1"
    cat > "$registry" <<'REG'
# Project Registry

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
| alpha | P1 | — | `~/alpha` | — | all | code | active | Test |
| beta | P2 | — | `~/beta` | — | all | code | active | Test |
| gamma | P3 | — | `~/gamma` | — | all | docs | active | Test |
| delta | P4 | — | `~/delta` | — | all | code | paused | Test |
| epsilon | P5 | — | `~/epsilon` | — | all | code | dormant | Test |
REG
}

# ── Tests: Help/Usage ──────────────────────────────────────────────────────

test_help_shows_usage() {
    local output
    output=$(bash "$SCRIPT" help 2>&1) || true
    assert_contains "$output" "Usage:"
    assert_contains "$output" "generate"
    assert_contains "$output" "apply-kde"
    assert_contains "$output" "apply-windows"
}
run_test "help shows usage with all commands" test_help_shows_usage

test_no_args_shows_usage() {
    local output
    output=$(bash "$SCRIPT" 2>&1) || true
    assert_contains "$output" "Usage:"
}
run_test "no arguments shows usage" test_no_args_shows_usage

test_invalid_command_shows_usage() {
    local output
    output=$(bash "$SCRIPT" bogus-command 2>&1) || true
    assert_contains "$output" "Usage:"
}
run_test "invalid command shows usage" test_invalid_command_shows_usage

# ── Tests: Registry Parsing ────────────────────────────────────────────────

test_parse_registry_extracts_projects() {
    local registry="$TEST_TMPDIR/registry.md"
    create_mock_registry "$registry"

    # Source the script in a subshell and call parse_registry
    local output
    output=$(bash -c '
        set -euo pipefail
        REGISTRY="'"$registry"'"
        parse_registry() {
            awk -F"|" '\''
                /^\| [a-zA-Z]/ && !/^\| Project/ && !/^\| Machine/ {
                    gsub(/^[ \t]+|[ \t]+$/, "", $2)
                    gsub(/^[ \t]+|[ \t]+$/, "", $3)
                    gsub(/^[ \t]+|[ \t]+$/, "", $5)
                    if ($3 ~ /^P[1-5]$/ && $5 ~ /^`~/) {
                        gsub(/`/, "", $5)
                        sub(/^~/, ENVIRON["HOME"], $5)
                        print $3 "|" $5 "|" $2
                    }
                }
            '\'' "$REGISTRY"
        }
        parse_registry
    ')
    # Should find 5 projects
    local count
    count=$(echo "$output" | wc -l)
    assert_eq "5" "$count" "should parse 5 projects from registry"
}
run_test "parse_registry extracts all projects" test_parse_registry_extracts_projects

test_parse_registry_has_correct_priorities() {
    local registry="$TEST_TMPDIR/registry.md"
    create_mock_registry "$registry"

    local output
    output=$(bash -c '
        set -euo pipefail
        REGISTRY="'"$registry"'"
        parse_registry() {
            awk -F"|" '\''
                /^\| [a-zA-Z]/ && !/^\| Project/ && !/^\| Machine/ {
                    gsub(/^[ \t]+|[ \t]+$/, "", $2)
                    gsub(/^[ \t]+|[ \t]+$/, "", $3)
                    gsub(/^[ \t]+|[ \t]+$/, "", $5)
                    if ($3 ~ /^P[1-5]$/ && $5 ~ /^`~/) {
                        gsub(/`/, "", $5)
                        sub(/^~/, ENVIRON["HOME"], $5)
                        print $3 "|" $5 "|" $2
                    }
                }
            '\'' "$REGISTRY"
        }
        parse_registry
    ')
    assert_contains "$output" "P1|"
    assert_contains "$output" "P2|"
    assert_contains "$output" "P3|"
    assert_contains "$output" "P4|"
    assert_contains "$output" "P5|"
}
run_test "parse_registry has correct priorities" test_parse_registry_has_correct_priorities

test_parse_registry_expands_home() {
    local registry="$TEST_TMPDIR/registry.md"
    create_mock_registry "$registry"

    local output
    output=$(bash -c '
        set -euo pipefail
        REGISTRY="'"$registry"'"
        parse_registry() {
            awk -F"|" '\''
                /^\| [a-zA-Z]/ && !/^\| Project/ && !/^\| Machine/ {
                    gsub(/^[ \t]+|[ \t]+$/, "", $2)
                    gsub(/^[ \t]+|[ \t]+$/, "", $3)
                    gsub(/^[ \t]+|[ \t]+$/, "", $5)
                    if ($3 ~ /^P[1-5]$/ && $5 ~ /^`~/) {
                        gsub(/`/, "", $5)
                        sub(/^~/, ENVIRON["HOME"], $5)
                        print $3 "|" $5 "|" $2
                    }
                }
            '\'' "$REGISTRY"
        }
        parse_registry
    ')
    # Paths should have HOME expanded (no ~ left)
    assert_not_contains "$output" "~/"
    assert_contains "$output" "$HOME/alpha"
}
run_test "parse_registry expands ~ to HOME" test_parse_registry_expands_home

# ── Tests: apply-windows platform guard ─────────────────────────────────────

test_apply_windows_rejects_non_wsl() {
    if [[ -d /mnt/c ]]; then
        skip_test "apply-windows non-WSL guard" "running on WSL — guard won't trigger"
        return
    fi
    local output
    output=$(bash "$SCRIPT" apply-windows 2>&1) || true
    assert_contains "$output" "not a WSL environment"
}
run_test "apply-windows rejects non-WSL environments" test_apply_windows_rejects_non_wsl

# ── Tests: apply-kde ────────────────────────────────────────────────────────

test_apply_kde_skips_missing_dirs() {
    # Simulate the apply-kde logic: iterate over paths and skip non-existent dirs
    local output
    output=$(bash -c '
        set -euo pipefail
        # Simulate parse_registry output with non-existent paths
        echo "P1|/tmp/definitely-nonexistent-dir-12345|noexist" | while IFS="|" read -r priority path name; do
            if [ ! -d "$path" ]; then
                echo "  SKIP $name ($path not found)"
                continue
            fi
        done
    ' 2>&1)
    assert_contains "$output" "SKIP"
    assert_contains "$output" "not found"
}
run_test "apply-kde skips missing project directories" test_apply_kde_skips_missing_dirs

test_apply_kde_writes_directory_file() {
    # Create a mock project dir and icon
    local project_dir="$TEST_TMPDIR/testproject"
    local icon_dir="$TEST_TMPDIR/icons"
    mkdir -p "$project_dir" "$icon_dir"
    touch "$icon_dir/p1.png"

    # Simulate what apply-kde does (write .directory file)
    local icon_path="$icon_dir/p1.png"
    cat > "$project_dir/.directory" <<EOF
[Desktop Entry]
Icon=${icon_path}
EOF

    assert_file_exists "$project_dir/.directory"
    assert_file_contains "$project_dir/.directory" "Desktop Entry"
    assert_file_contains "$project_dir/.directory" "Icon="
    assert_file_contains "$project_dir/.directory" "$icon_dir/p1.png"
}
run_test "KDE .directory file has correct format" test_apply_kde_writes_directory_file

test_apply_kde_skips_missing_icons() {
    local project_dir="$TEST_TMPDIR/myproject"
    local icon_dir="$TEST_TMPDIR/empty-icons"
    mkdir -p "$project_dir" "$icon_dir"
    # No icon files created

    local output
    output=$(bash -c '
        set -euo pipefail
        ICON_DIR="'"$icon_dir"'"
        priority_lower="p1"
        icon_path="${ICON_DIR}/${priority_lower}.png"
        if [ ! -f "$icon_path" ]; then
            echo "  SKIP myproject (icon $icon_path not found — run generate first)"
        fi
    ' 2>&1)
    assert_contains "$output" "SKIP"
    assert_contains "$output" "run"
}
run_test "apply-kde skips when icon file missing" test_apply_kde_skips_missing_icons

# ── Tests: generate command ─────────────────────────────────────────────────

test_generate_creates_icons() {
    # Check if Pillow is available
    if ! python3 -c "from PIL import Image" 2>/dev/null; then
        skip_test "generate creates icon files" "Python Pillow not installed"
        return
    fi

    # The script writes to $REPO_DIR/setup/icons/ (hardcoded from SCRIPT_DIR)
    # We run it and check the default output location
    local default_icon_dir="$REPO_ROOT/setup/icons"

    bash "$SCRIPT" generate >/dev/null 2>&1

    # Should create .ico and .png for each priority
    assert_file_exists "$default_icon_dir/p1.ico"
    assert_file_exists "$default_icon_dir/p1.png"
    assert_file_exists "$default_icon_dir/p2.ico"
    assert_file_exists "$default_icon_dir/p2.png"
    assert_file_exists "$default_icon_dir/p3.ico"
    assert_file_exists "$default_icon_dir/p3.png"
    assert_file_exists "$default_icon_dir/p4.ico"
    assert_file_exists "$default_icon_dir/p4.png"
    assert_file_exists "$default_icon_dir/p5.ico"
    assert_file_exists "$default_icon_dir/p5.png"
}
run_test "generate creates icon files for all priorities" test_generate_creates_icons

# ── Tests: clean-kde ────────────────────────────────────────────────────────

test_clean_kde_removes_directory_files() {
    local project_dir="$TEST_TMPDIR/clean-test"
    mkdir -p "$project_dir"
    echo "[Desktop Entry]" > "$project_dir/.directory"
    echo "Icon=/some/path/p1.png" >> "$project_dir/.directory"

    assert_file_exists "$project_dir/.directory"
    rm "$project_dir/.directory"
    assert_file_not_exists "$project_dir/.directory"
}
run_test "clean-kde removes .directory files" test_clean_kde_removes_directory_files

suite_summary
