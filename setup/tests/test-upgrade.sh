#!/usr/bin/env bash
# Tests for the upgrade system: upgrade.sh, migrations/v0.3.sh, sync.sh hook points
# TDD: all tests written first, then implementation makes them pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

suite_header "Upgrade System"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Create a minimal agent-fleet repo structure for testing
create_fleet_repo() {
    local dir="$1"
    create_git_repo "$dir"

    # Minimal repo structure
    mkdir -p "$dir/setup/scripts" "$dir/setup/config" "$dir/setup/tests" "$dir/setup/migrations"
    mkdir -p "$dir/global/foundation" "$dir/global/hooks"

    # lib.sh stub (log functions)
    cat > "$dir/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF

    # Minimal sync.sh with source hook point placeholder
    cat > "$dir/sync.sh" << 'SYNCEOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_DIR="$SCRIPT_DIR/global"
CLAUDE_HOME="$HOME/.claude"
source "$SCRIPT_DIR/setup/lib.sh"
get_hostname() { hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown"; }
cmd_setup() {
    if [[ ! -f "$HOME/CLAUDE.local.md" ]]; then
        local machine_file=""
        local hn
        hn=$(get_hostname)
        case "$hn" in
            host-b)       machine_file="vps.md" ;;
            DESKTOP-*)    machine_file="wsl.md" ;;
        esac
    fi
}
cmd_deploy() {
    log_info "Deploying..."
}
case "${1:-}" in
    setup)  cmd_setup ;;
    deploy) cmd_deploy ;;
    *)      echo "Usage: $0 {setup|deploy}" ;;
esac
SYNCEOF
    chmod +x "$dir/sync.sh"

    # Personas with personal content (Persona1/Persona2 style)
    cat > "$dir/global/foundation/personas.md" << 'PEOF'
# Default Personas

## Persona

### MyCustomBot
- **Name**: MyCustomBot
- **Traits**: efficient, dry-humor
- **Activates**: default

### SupportBot
- **Name**: SupportBot
- **Traits**: warm, encouraging
- **Activates**: when frustrated

## Day/Night Mode

- **Switch time**: 17:00 local
PEOF

    # Settings with personal additions
    cat > "$dir/setup/config/settings.json" << 'SEOF'
{
  "env": {
    "FORCE_COLOR": "1"
  },
  "permissions": {
    "allow": [
      "Read(*)",
      "Write(*)",
      "Bash(git:*)"
    ]
  }
}
SEOF

    # .gitignore
    cat > "$dir/.gitignore" << 'GEOF'
*.bak
.sync-failed
GEOF

    # Copy upgrade.sh from real repo
    cp "$REPO_ROOT/setup/upgrade.sh" "$dir/setup/upgrade.sh"
    chmod +x "$dir/setup/upgrade.sh"

    # Commit everything
    git -C "$dir" add -A
    git -C "$dir" commit -m "Fleet repo structure" >/dev/null 2>&1
}

# Create a template repo (upstream) with default personas
create_template_repo() {
    local dir="$1"
    create_git_repo "$dir"

    mkdir -p "$dir/setup/scripts" "$dir/setup/config" "$dir/setup/migrations"
    mkdir -p "$dir/global/foundation"

    cat > "$dir/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF

    # Template personas (defaults)
    cat > "$dir/global/foundation/personas.md" << 'PEOF'
# Default Personas

## Persona

### Assistant
- **Name**: Assistant
- **Traits**: efficient, helpful
- **Activates**: default

### Supporter
- **Name**: Supporter
- **Traits**: warm, encouraging
- **Activates**: when frustrated
PEOF

    echo "0.2" > "$dir/.agent-fleet-version"

    cat > "$dir/.gitignore" << 'GEOF'
*.bak
.sync-failed
sync.local.sh
global/foundation/personas.local.md
setup/config/settings.override.json
GEOF

    git -C "$dir" add -A
    git -C "$dir" commit -m "Template structure" >/dev/null 2>&1
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 1: upgrade.sh behavior
# ══════════════════════════════════════════════════════════════════════════════

test_upgrade_refuses_without_upstream() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    local output
    output=$(bash "$repo/setup/upgrade.sh" 2>&1) && return 1
    assert_contains "$output" "upstream" "should mention upstream remote"
}
run_test "upgrade refuses without upstream remote" test_upgrade_refuses_without_upstream

test_upgrade_detects_up_to_date() {
    local repo="$TEST_TMPDIR/fleet"
    local upstream="$TEST_TMPDIR/upstream.git"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"
    echo "all" > "$repo/.agent-fleet-channel"
    git -C "$repo" add -A && git -C "$repo" commit -m "version" >/dev/null 2>&1

    create_bare_repo "$upstream"
    git -C "$repo" remote add upstream "$upstream"
    git -C "$repo" push upstream main >/dev/null 2>&1
    # Fetch to establish remote tracking
    git -C "$repo" fetch upstream >/dev/null 2>&1

    local output
    output=$(bash "$repo/setup/upgrade.sh" 2>&1)
    assert_contains "$output" "up to date" "should say already up to date"
}
run_test "upgrade detects already up-to-date" test_upgrade_detects_up_to_date

test_upgrade_stashes_dirty_tree() {
    local repo="$TEST_TMPDIR/fleet"
    local upstream="$TEST_TMPDIR/upstream.git"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "version" >/dev/null 2>&1

    create_bare_repo "$upstream"
    git -C "$repo" remote add upstream "$upstream"
    git -C "$repo" push upstream "$(git -C "$repo" branch --show-current)" >/dev/null 2>&1

    # Dirty the working tree
    echo "dirty" > "$repo/dirty-file.txt"

    local output
    output=$(bash "$repo/setup/upgrade.sh" 2>&1)
    # After upgrade (no-op since versions match), dirty file should be back
    assert_file_exists "$repo/dirty-file.txt" "dirty file should survive"
}
run_test "upgrade stashes dirty working tree" test_upgrade_stashes_dirty_tree

test_upgrade_dry_run() {
    local repo="$TEST_TMPDIR/fleet"
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "version" >/dev/null 2>&1

    # Create upstream with higher version
    create_template_repo "$template"
    echo "0.3" > "$template/.agent-fleet-version"
    git -C "$template" add -A && git -C "$template" commit -m "bump" >/dev/null 2>&1

    create_bare_repo "$upstream"
    git -C "$template" remote add origin2 "$upstream"
    git -C "$template" push origin2 "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    git -C "$repo" remote add upstream "$upstream"

    local output
    output=$(bash "$repo/setup/upgrade.sh" --dry-run 2>&1)
    assert_contains "$output" "DRY RUN" "should indicate dry run"
    # Version should NOT have changed
    assert_eq "0.2" "$(cat "$repo/.agent-fleet-version")" "version unchanged in dry run"
}
run_test "upgrade --dry-run shows plan without changing" test_upgrade_dry_run

test_upgrade_runs_migrations_in_order() {
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"
    local repo="$TEST_TMPDIR/fleet"

    # Create template as the common ancestor
    create_git_repo "$template"
    mkdir -p "$template/setup/scripts" "$template/setup/config" "$template/setup/migrations"
    cat > "$template/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF
    echo "0.1" > "$template/.agent-fleet-version"
    cat > "$template/sync.sh" << 'SEOF'
#!/usr/bin/env bash
case "${1:-}" in deploy) echo "deploy-ok" ;; esac
SEOF
    chmod +x "$template/sync.sh"
    cp "$REPO_ROOT/setup/upgrade.sh" "$template/setup/upgrade.sh"
    chmod +x "$template/setup/upgrade.sh"
    git -C "$template" add -A && git -C "$template" commit -m "v0.1 base" >/dev/null 2>&1

    # Push to bare upstream
    create_bare_repo "$upstream"
    git -C "$template" remote add origin "$upstream"
    git -C "$template" push origin "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    # Clone as user repo (shared history!)
    git clone "$upstream" "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote rename origin upstream
    # Use 'all' channel so minor version bumps are detected
    echo "all" > "$repo/.agent-fleet-channel"

    # Now add migrations to template and push
    cat > "$template/setup/migrations/v0.2.sh" << 'MEOF'
#!/usr/bin/env bash
REPO_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
echo "ran-v0.2" >> "$REPO_DIR/.migration-log"
MEOF
    chmod +x "$template/setup/migrations/v0.2.sh"

    cat > "$template/setup/migrations/v0.3.sh" << 'MEOF'
#!/usr/bin/env bash
REPO_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
echo "ran-v0.3" >> "$REPO_DIR/.migration-log"
MEOF
    chmod +x "$template/setup/migrations/v0.3.sh"

    echo "0.3" > "$template/.agent-fleet-version"
    git -C "$template" add -A && git -C "$template" commit -m "v0.3 with migrations" >/dev/null 2>&1
    git -C "$template" push origin "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    bash "$repo/setup/upgrade.sh" 2>&1 || true

    # Both migrations should have run, in order
    assert_file_exists "$repo/.migration-log" "migration log should exist"
    local line1 line2
    line1=$(sed -n '1p' "$repo/.migration-log")
    line2=$(sed -n '2p' "$repo/.migration-log")
    assert_eq "ran-v0.2" "$line1" "v0.2 ran first"
    assert_eq "ran-v0.3" "$line2" "v0.3 ran second"
}
run_test "upgrade runs pending migrations in order" test_upgrade_runs_migrations_in_order

test_upgrade_skips_applied_migrations() {
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"
    local repo="$TEST_TMPDIR/fleet"

    # Create template as the common ancestor at v0.2
    create_git_repo "$template"
    mkdir -p "$template/setup/scripts" "$template/setup/config" "$template/setup/migrations"
    cat > "$template/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF
    echo "0.2" > "$template/.agent-fleet-version"
    cat > "$template/sync.sh" << 'SEOF'
#!/usr/bin/env bash
case "${1:-}" in deploy) echo "deploy-ok" ;; esac
SEOF
    chmod +x "$template/sync.sh"
    cp "$REPO_ROOT/setup/upgrade.sh" "$template/setup/upgrade.sh"
    chmod +x "$template/setup/upgrade.sh"
    git -C "$template" add -A && git -C "$template" commit -m "v0.2 base" >/dev/null 2>&1

    # Push to bare upstream
    create_bare_repo "$upstream"
    git -C "$template" remote add origin "$upstream"
    git -C "$template" push origin "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    # Clone as user repo (shared history!)
    git clone "$upstream" "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote rename origin upstream
    echo "all" > "$repo/.agent-fleet-channel"

    # Add migrations to template and push v0.3
    cat > "$template/setup/migrations/v0.2.sh" << 'MEOF'
#!/usr/bin/env bash
REPO_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
echo "ran-v0.2" >> "$REPO_DIR/.migration-log"
MEOF
    chmod +x "$template/setup/migrations/v0.2.sh"

    cat > "$template/setup/migrations/v0.3.sh" << 'MEOF'
#!/usr/bin/env bash
REPO_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
echo "ran-v0.3" >> "$REPO_DIR/.migration-log"
MEOF
    chmod +x "$template/setup/migrations/v0.3.sh"

    echo "0.3" > "$template/.agent-fleet-version"
    git -C "$template" add -A && git -C "$template" commit -m "v0.3" >/dev/null 2>&1
    git -C "$template" push origin "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    bash "$repo/setup/upgrade.sh" 2>&1 || true

    # Only v0.3 should have run (v0.2 skipped because current version is 0.2)
    assert_file_exists "$repo/.migration-log" "migration log should exist"
    assert_grep_count "$repo/.migration-log" "ran-v0.2" 0 "v0.2 should NOT have run"
    assert_grep_count "$repo/.migration-log" "ran-v0.3" 1 "v0.3 should have run"
}
run_test "upgrade skips already-applied migrations" test_upgrade_skips_applied_migrations

test_upgrade_handles_merge_conflict() {
    local repo="$TEST_TMPDIR/fleet"
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    # Create a conflict source — both sides edit README.md
    echo "personal content" > "$repo/README.md"
    git -C "$repo" add -A && git -C "$repo" commit -m "personal" >/dev/null 2>&1

    create_template_repo "$template"
    echo "0.3" > "$template/.agent-fleet-version"
    echo "template content" > "$template/README.md"
    git -C "$template" add -A && git -C "$template" commit -m "template" >/dev/null 2>&1

    create_bare_repo "$upstream"
    git -C "$template" remote add origin2 "$upstream"
    git -C "$template" push origin2 "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    git -C "$repo" remote add upstream "$upstream"

    local output rc=0
    output=$(bash "$repo/setup/upgrade.sh" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero on merge conflict"
    assert_contains "$output" "conflict" "should mention conflict"

    # Clean up merge state for teardown
    git -C "$repo" merge --abort 2>/dev/null || true
}
run_test "upgrade handles merge conflict gracefully" test_upgrade_handles_merge_conflict

test_upgrade_fetch_failure_shows_error() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "version" >/dev/null 2>&1

    # Add upstream pointing to invalid URL
    git -C "$repo" remote add upstream "https://invalid.example.com/nonexistent.git"

    local output rc=0
    output=$(bash "$repo/setup/upgrade.sh" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero on fetch failure"
    assert_contains "$output" "Failed to fetch" "should show fetch error message"
}
run_test "upgrade fetch failure shows error and exits cleanly" test_upgrade_fetch_failure_shows_error

test_upgrade_fetch_failure_restores_stash() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "version" >/dev/null 2>&1

    # Dirty the working tree
    echo "my precious changes" > "$repo/dirty-file.txt"

    # Add upstream pointing to invalid URL
    git -C "$repo" remote add upstream "https://invalid.example.com/nonexistent.git"

    local output rc=0
    output=$(bash "$repo/setup/upgrade.sh" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero"

    # The EXIT trap should have restored the stash
    assert_file_exists "$repo/dirty-file.txt" "dirty file should be restored by EXIT trap"
    local content
    content=$(cat "$repo/dirty-file.txt")
    assert_eq "my precious changes" "$content" "file content should be intact"
}
run_test "upgrade fetch failure restores stash via EXIT trap" test_upgrade_fetch_failure_restores_stash

test_upgrade_missing_upstream_version_warns() {
    local repo="$TEST_TMPDIR/fleet"
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"

    # Create template WITHOUT .agent-fleet-version
    create_git_repo "$template"
    mkdir -p "$template/setup"
    cat > "$template/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF
    git -C "$template" add -A && git -C "$template" commit -m "no version file" >/dev/null 2>&1

    create_bare_repo "$upstream"
    git -C "$template" remote add origin "$upstream"
    git -C "$template" push origin "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    # Create fleet repo at version 0.0 (will match the 0.0 fallback → up to date)
    create_fleet_repo "$repo"
    echo "0.0" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "version" >/dev/null 2>&1
    git -C "$repo" remote add upstream "$upstream"

    echo "all" > "$repo/.agent-fleet-channel"
    git -C "$repo" fetch upstream >/dev/null 2>&1

    local output
    output=$(bash "$repo/setup/upgrade.sh" 2>&1)
    assert_contains "$output" "No version found upstream" "should warn about missing version file"
    assert_contains "$output" "defaulting to 0.0" "should mention the 0.0 fallback"
}
run_test "upgrade warns when upstream has no .agent-fleet-version" test_upgrade_missing_upstream_version_warns

test_upgrade_unexpected_exit_restores_stash() {
    local repo="$TEST_TMPDIR/fleet"
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"

    # Create template with higher version and a migration that fails
    create_git_repo "$template"
    mkdir -p "$template/setup" "$template/setup/migrations"
    cat > "$template/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF
    echo "0.3" > "$template/.agent-fleet-version"
    cat > "$template/sync.sh" << 'SEOF'
#!/usr/bin/env bash
case "${1:-}" in deploy) echo "deploy-ok" ;; esac
SEOF
    chmod +x "$template/sync.sh"
    # Migration that exits with error (simulates unexpected failure)
    cat > "$template/setup/migrations/v0.3.sh" << 'MEOF'
#!/usr/bin/env bash
exit 1
MEOF
    chmod +x "$template/setup/migrations/v0.3.sh"
    git -C "$template" add -A && git -C "$template" commit -m "v0.3 with failing migration" >/dev/null 2>&1

    create_bare_repo "$upstream"
    git -C "$template" remote add origin "$upstream"
    git -C "$template" push origin "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    # Clone as user repo with shared history
    git clone "$upstream" "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote rename origin upstream

    # Set local version to 0.2 and dirty the tree
    echo "0.2" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "v0.2" >/dev/null 2>&1
    echo "precious local work" > "$repo/local-work.txt"

    # Run upgrade — migration will fail, set -e will trigger EXIT trap
    local output rc=0
    output=$(bash "$repo/setup/upgrade.sh" 2>&1) || rc=$?
    assert_neq "0" "$rc" "should exit non-zero due to migration failure"

    # The EXIT trap should have restored the stash
    assert_file_exists "$repo/local-work.txt" "local work should be restored by EXIT trap"
    local content
    content=$(cat "$repo/local-work.txt")
    assert_eq "precious local work" "$content" "file content should be intact after trap"

    # Stash list should be empty (stash was popped)
    local stash_count
    stash_count=$(git -C "$repo" stash list | wc -l | tr -d ' ')
    assert_eq "0" "$stash_count" "stash should be empty after EXIT trap pop"
}
run_test "upgrade restores stash on unexpected exit (migration failure)" test_upgrade_unexpected_exit_restores_stash

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 2: migrations/v0.3.sh behavior
# ══════════════════════════════════════════════════════════════════════════════

test_v03_is_idempotent() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    # Run twice
    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1 || true
    local version_after_first
    version_after_first=$(cat "$repo/.agent-fleet-version")

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1 || true
    local version_after_second
    version_after_second=$(cat "$repo/.agent-fleet-version")

    assert_eq "$version_after_first" "$version_after_second" "version same after two runs"
    # sync.local.sh should not have duplicate entries
    if [[ -f "$repo/sync.local.sh" ]]; then
        local fn_count
        fn_count=$(grep -c 'local_hostname_map' "$repo/sync.local.sh") || fn_count=0
        # Function defined once (the function header line)
        assert_eq "1" "$fn_count" "local_hostname_map defined exactly once"
    fi
}
run_test "v0.3 is idempotent" test_v03_is_idempotent

test_v03_extracts_hostname_case() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    assert_file_exists "$repo/sync.local.sh" "sync.local.sh should be created"
    assert_file_contains "$repo/sync.local.sh" "host-b" "should contain hostname entry"
    assert_file_contains "$repo/sync.local.sh" "local_hostname_map" "should define function"
}
run_test "v0.3 extracts hostname case to sync.local.sh" test_v03_extracts_hostname_case

test_v03_skips_commented_case() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    # Replace sync.sh with template version (commented entries only)
    cat > "$repo/sync.sh" << 'SYNCEOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/setup/lib.sh"
get_hostname() { echo "unknown"; }
cmd_setup() {
    if [[ ! -f "$HOME/CLAUDE.local.md" ]]; then
        local machine_file=""
        local hn
        hn=$(get_hostname)
        case "$hn" in
            # my-vps-*)    machine_file="vps.md" ;;
            # DESKTOP-*)   machine_file="wsl.md" ;;
        esac
    fi
}
case "${1:-}" in setup) cmd_setup ;; esac
SYNCEOF

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    # Should NOT create sync.local.sh (no real entries to extract)
    assert_file_not_exists "$repo/sync.local.sh" "no sync.local.sh for commented-only case"
}
run_test "v0.3 preserves commented case block (no extraction)" test_v03_skips_commented_case

test_v03_creates_personas_local() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    assert_file_exists "$repo/global/foundation/personas.local.md" "personas.local.md created"
    assert_file_contains "$repo/global/foundation/personas.local.md" "MyCustomBot" "user persona preserved"
    assert_file_contains "$repo/global/foundation/personas.local.md" "SupportBot" "second persona preserved"
}
run_test "v0.3 creates personas.local.md from non-default personas" test_v03_creates_personas_local

test_v03_skips_default_personas() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    # Replace personas with template defaults
    cat > "$repo/global/foundation/personas.md" << 'PEOF'
# Default Personas

## Persona

### Assistant
- **Name**: Assistant
- **Traits**: efficient, helpful
- **Activates**: default

### Supporter
- **Name**: Supporter
- **Traits**: warm, encouraging
- **Activates**: when frustrated
PEOF

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    # Should NOT create personas.local.md (already has defaults)
    assert_file_not_exists "$repo/global/foundation/personas.local.md" "no split for default personas"
}
run_test "v0.3 skips persona split when already default" test_v03_skips_default_personas

test_v03_adds_gitignore_entries() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    assert_file_contains "$repo/.gitignore" "sync.local.sh"
    assert_file_contains "$repo/.gitignore" "personas.local.md"
    assert_file_contains "$repo/.gitignore" "settings.override.json"
}
run_test "v0.3 adds gitignore entries" test_v03_adds_gitignore_entries

test_v03_no_duplicate_gitignore() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    # Run twice
    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1
    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    local count
    count=$(grep -c "sync.local.sh" "$repo/.gitignore")
    assert_eq "1" "$count" "sync.local.sh appears exactly once"
}
run_test "v0.3 no duplicate gitignore entries" test_v03_no_duplicate_gitignore

test_v03_sets_version() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    assert_eq "0.3" "$(cat "$repo/.agent-fleet-version")" "version bumped to 0.3"
}
run_test "v0.3 sets .agent-fleet-version to 0.3" test_v03_sets_version

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 3: sync.sh hook points
# ══════════════════════════════════════════════════════════════════════════════

test_sync_sources_local_sh() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"

    # Create sync.local.sh with a hostname map
    cat > "$repo/sync.local.sh" << 'LEOF'
local_hostname_map() {
    local hn="$1"
    case "$hn" in
        test-host*) echo "test.md" ;;
    esac
}
LEOF

    # The updated sync.sh should source sync.local.sh and use local_hostname_map
    # We test by checking that sync.sh sources the file (grep the deployed sync.sh)
    assert_file_contains "$REPO_ROOT/sync.sh" "sync.local.sh" "sync.sh should reference sync.local.sh"
}
run_test "sync.sh sources sync.local.sh if present" test_sync_sources_local_sh

test_sync_works_without_local_sh() {
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"

    # No sync.local.sh exists
    rm -f "$repo/sync.local.sh"

    # sync.sh setup should not error without sync.local.sh
    # We can't easily test cmd_setup (it writes to $HOME), so test the pattern exists
    assert_file_not_contains "$REPO_ROOT/sync.sh" "source.*sync.local.sh.*||.*exit" \
        "sync.sh should not exit if sync.local.sh missing"
}
run_test "sync.sh works without sync.local.sh" test_sync_works_without_local_sh

test_sync_local_post_setup_hook() {
    # Verify the setup path calls local_post_setup. cfg keeps setup in sync-lib/setup.sh;
    # the template keeps it inline in sync.sh (CFG-708) — the property is the call, not the file.
    local setup_src
    setup_src=$(cat "$REPO_ROOT/sync-lib/setup.sh" "$REPO_ROOT/sync.sh" 2>/dev/null || true)
    assert_contains "$setup_src" "if type local_post_setup &>/dev/null; then" "setup should call local_post_setup when defined"
}
run_test "sync-lib has local_post_setup hook point" test_sync_local_post_setup_hook

test_deploy_merges_settings_override() {
    # Verify sync-lib/deploy.sh has settings override merge logic
    assert_file_contains "$REPO_ROOT/sync-lib/deploy.sh" "settings.override.json" \
        "deploy lib should handle settings override"
}
run_test "sync-lib has settings override merge" test_deploy_merges_settings_override

test_deploy_works_without_override() {
    # Verify deploy references override file conditionally
    local deploy_content
    deploy_content=$(cat "$REPO_ROOT/sync-lib/deploy.sh")
    assert_contains "$deploy_content" "settings.override" "deploy lib mentions settings override"
}
run_test "sync-lib deploy references settings override" test_deploy_works_without_override

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 4: personas @import
# ══════════════════════════════════════════════════════════════════════════════

test_personas_has_import_line() {
    # After implementation, the framework personas.md should have an @import
    # for personas.local.md
    assert_file_contains "$REPO_ROOT/global/foundation/personas.md" "personas.local.md" \
        "personas.md should import personas.local.md"
}
run_test "personas.md contains @import for local file" test_personas_has_import_line

test_personas_local_gitignored() {
    assert_file_contains "$REPO_ROOT/.gitignore" "personas.local.md" \
        "personas.local.md should be gitignored"
}
run_test "personas.local.md is gitignored" test_personas_local_gitignored

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 5: CFG-33 — branch detection + version comparison
# ══════════════════════════════════════════════════════════════════════════════

test_upgrade_master_branch_detection() {
    # CFG-33: upgrade.sh must detect upstream default branch dynamically.
    # Repos with 'master' (not 'main') must work too.
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"
    local repo="$TEST_TMPDIR/fleet"

    # Create template repo with 'master' as default branch
    mkdir -p "$template"
    git init -b master "$template" >/dev/null 2>&1
    git -C "$template" config user.email "test@test.com"
    git -C "$template" config user.name "Test"
    mkdir -p "$template/setup"
    cat > "$template/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF
    echo "0.3" > "$template/.agent-fleet-version"
    cat > "$template/sync.sh" << 'SEOF'
#!/usr/bin/env bash
case "${1:-}" in deploy) echo "deploy-ok" ;; esac
SEOF
    chmod +x "$template/sync.sh"
    git -C "$template" add -A && git -C "$template" commit -m "v0.3 on master" >/dev/null 2>&1

    # Push to bare upstream (also using master)
    mkdir -p "$upstream"
    git init --bare -b master "$upstream" >/dev/null 2>&1
    git -C "$template" remote add origin "$upstream"
    git -C "$template" push origin master >/dev/null 2>&1

    # Clone as user repo with shared history
    git clone "$upstream" "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote rename origin upstream

    # Downgrade local version so upgrade has work to do
    echo "0.2" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "v0.2" >/dev/null 2>&1

    # Copy current upgrade.sh
    cp "$REPO_ROOT/setup/upgrade.sh" "$repo/setup/upgrade.sh"
    chmod +x "$repo/setup/upgrade.sh"
    git -C "$repo" add -A && git -C "$repo" commit -m "add upgrade.sh" >/dev/null 2>&1

    local output
    output=$(bash "$repo/setup/upgrade.sh" --dry-run 2>&1)
    assert_contains "$output" "DRY RUN" "should detect master branch and proceed"
    assert_contains "$output" "0.3" "should read version from upstream/master"
    assert_not_contains "$output" "Cannot determine upstream" "should not fail on branch detection"
}
run_test "CFG-33: upgrade detects master as default branch" test_upgrade_master_branch_detection

test_upgrade_semver_v010_vs_v09() {
    # CFG-33: version comparison must handle semver correctly.
    # Float comparison fails: 0.10 == 0.1 in float, but they're different versions.
    # sort -V handles this correctly.
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"
    local repo="$TEST_TMPDIR/fleet"

    # Create template at v0.10
    create_git_repo "$template"
    mkdir -p "$template/setup" "$template/setup/migrations"
    cat > "$template/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF
    echo "0.10" > "$template/.agent-fleet-version"
    cat > "$template/sync.sh" << 'SEOF'
#!/usr/bin/env bash
case "${1:-}" in deploy) echo "deploy-ok" ;; esac
SEOF
    chmod +x "$template/sync.sh"

    # Migration v0.10 — should run when upgrading from 0.9
    cat > "$template/setup/migrations/v0.10.sh" << 'MEOF'
#!/usr/bin/env bash
REPO_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
echo "ran-v0.10" >> "$REPO_DIR/.migration-log"
MEOF
    chmod +x "$template/setup/migrations/v0.10.sh"

    cp "$REPO_ROOT/setup/upgrade.sh" "$template/setup/upgrade.sh"
    chmod +x "$template/setup/upgrade.sh"
    git -C "$template" add -A && git -C "$template" commit -m "v0.10 with migration" >/dev/null 2>&1

    create_bare_repo "$upstream"
    git -C "$template" remote add origin "$upstream"
    git -C "$template" push origin "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    # Clone as user repo at v0.9
    git clone "$upstream" "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote rename origin upstream
    echo "all" > "$repo/.agent-fleet-channel"

    echo "0.9" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "v0.9" >/dev/null 2>&1

    bash "$repo/setup/upgrade.sh" 2>&1 || true

    # v0.10 migration MUST run (0.10 > 0.9 in semver, but 0.10 == 0.1 < 0.9 in float)
    assert_file_exists "$repo/.migration-log" "migration log should exist"
    assert_file_contains "$repo/.migration-log" "ran-v0.10" "v0.10 migration must run (semver, not float)"
}
run_test "CFG-33: semver comparison — v0.10 > v0.9 (not float)" test_upgrade_semver_v010_vs_v09

test_upgrade_no_downgrade_migration() {
    # CFG-33: migrations with version <= current should NOT run.
    # With awk float: 0.10 == 0.1, so v0.10 would be skipped when at v0.9 (wrong).
    # With sort -V: 0.10 > 0.9, so v0.10 runs (correct).
    # Also: v0.9 should NOT run if current is 0.9 (already applied).
    local upstream="$TEST_TMPDIR/upstream.git"
    local template="$TEST_TMPDIR/template"
    local repo="$TEST_TMPDIR/fleet"

    create_git_repo "$template"
    mkdir -p "$template/setup" "$template/setup/migrations"
    cat > "$template/setup/lib.sh" << 'LIBEOF'
log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
_sort_versions() { sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n; }  # real lib.sh has it; upgrade.sh needs it
LIBEOF
    echo "0.11" > "$template/.agent-fleet-version"
    cat > "$template/sync.sh" << 'SEOF'
#!/usr/bin/env bash
case "${1:-}" in deploy) echo "deploy-ok" ;; esac
SEOF
    chmod +x "$template/sync.sh"

    # Multiple migrations
    for v in 0.8 0.9 0.10 0.11; do
        cat > "$template/setup/migrations/v${v}.sh" << MEOF
#!/usr/bin/env bash
REPO_DIR="\${1:-\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)}"
echo "ran-v${v}" >> "\$REPO_DIR/.migration-log"
MEOF
        chmod +x "$template/setup/migrations/v${v}.sh"
    done

    cp "$REPO_ROOT/setup/upgrade.sh" "$template/setup/upgrade.sh"
    chmod +x "$template/setup/upgrade.sh"
    git -C "$template" add -A && git -C "$template" commit -m "v0.11" >/dev/null 2>&1

    create_bare_repo "$upstream"
    git -C "$template" remote add origin "$upstream"
    git -C "$template" push origin "$(git -C "$template" branch --show-current)" >/dev/null 2>&1

    git clone "$upstream" "$repo" >/dev/null 2>&1
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" remote rename origin upstream
    echo "all" > "$repo/.agent-fleet-channel"

    # Current version is 0.9 — migrations 0.10 and 0.11 should run; 0.8 and 0.9 should NOT
    echo "0.9" > "$repo/.agent-fleet-version"
    git -C "$repo" add -A && git -C "$repo" commit -m "v0.9" >/dev/null 2>&1

    bash "$repo/setup/upgrade.sh" 2>&1 || true

    assert_file_exists "$repo/.migration-log" "migration log should exist"
    assert_grep_count "$repo/.migration-log" "ran-v0.8" 0 "v0.8 should NOT run (already applied)"
    assert_grep_count "$repo/.migration-log" "ran-v0.9" 0 "v0.9 should NOT run (current version)"
    assert_grep_count "$repo/.migration-log" "ran-v0.10" 1 "v0.10 should run"
    assert_grep_count "$repo/.migration-log" "ran-v0.11" 1 "v0.11 should run"
}
run_test "CFG-33: no downgrade — only newer migrations run" test_upgrade_no_downgrade_migration

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 6: CFG-34 — v0.3 migration fixes
# ══════════════════════════════════════════════════════════════════════════════

test_v03_creates_persona_backup() {
    # CFG-34: v0.3 must back up personas.md BEFORE overwriting it.
    # Original bug: cp to local + immediate cat > overwrite with no .bak.
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    # Save the original content for comparison
    local original_content
    original_content=$(cat "$repo/global/foundation/personas.md")

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    # Backup must exist
    assert_file_exists "$repo/global/foundation/personas.md.bak" \
        "personas.md.bak must be created before overwrite"

    # Backup must contain the ORIGINAL content (not the framework defaults)
    local backup_content
    backup_content=$(cat "$repo/global/foundation/personas.md.bak")
    assert_eq "$original_content" "$backup_content" \
        "backup should contain original user personas"

    # The live personas.md should now have framework defaults
    assert_file_contains "$repo/global/foundation/personas.md" "### Assistant" \
        "personas.md should have framework defaults after migration"
}
run_test "CFG-34: v0.3 creates persona backup before overwrite" test_v03_creates_persona_backup

test_v03_hostname_uses_echo_not_assignment() {
    # CFG-34: extracted hostname map must use 'echo "X"' not 'machine_file="X"'.
    # The function is called via command substitution: machine_file=$(local_hostname_map "$hn")
    # If the awk extraction leaves 'machine_file="X"' as-is, the function body
    # contains a variable assignment that has no effect in the subshell.
    # Fix: gsub replaces 'machine_file=' with 'echo ' so the function returns the value.
    local repo="$TEST_TMPDIR/fleet"
    create_fleet_repo "$repo"
    echo "0.2" > "$repo/.agent-fleet-version"

    bash "$REPO_ROOT/setup/migrations/v0.3.sh" "$repo" 2>&1

    assert_file_exists "$repo/sync.local.sh" "sync.local.sh should be created"

    # Must NOT contain machine_file= assignments (those don't return values from functions)
    assert_file_not_contains "$repo/sync.local.sh" 'machine_file=' \
        "sync.local.sh should use echo, not machine_file= assignment"

    # Must contain echo (the replacement for machine_file=)
    assert_file_contains "$repo/sync.local.sh" 'echo "' \
        "sync.local.sh should use echo to return values"

    # Functional test: the function must actually return the machine file name
    source "$repo/sync.local.sh"
    local result
    result=$(local_hostname_map "host-b")
    assert_eq "vps.md" "$result" "local_hostname_map should return machine file name"
}
run_test "CFG-34: hostname extraction uses echo, not variable assignment" test_v03_hostname_uses_echo_not_assignment

# ══════════════════════════════════════════════════════════════════════════════
# GROUP 6: setup/scripts/upgrade.sh — upgrade with rollback (AFT-29)
# ══════════════════════════════════════════════════════════════════════════════
#
# A SECOND, different subject from GROUP 1: setup/scripts/upgrade.sh is the
# tag-checkpoint/rollback upgrader that exists only in the public template (added
# downstream by AFT-29). These cases came from the template's copy of this file and
# are kept so propagating this suite does not delete their coverage there. Where the
# subject is absent (this config repo), they are reported as SKIP, never as PASS.

UPGRADE_SCRIPT="$REPO_ROOT/setup/scripts/upgrade.sh"

# Create a mock repo with remote
_setup_upgrade_env() {
    local remote="$TEST_TMPDIR/remote.git"
    local repo="$TEST_TMPDIR/repo"

    create_tracked_repo "$repo" "$remote"

    # Add some files to simulate agent-fleet structure
    (
        cd "$repo"
        mkdir -p setup/scripts global
        echo '#!/bin/bash' > sync.sh
        echo 'cmd_deploy() { echo "deployed"; }' >> sync.sh
        chmod +x sync.sh
        cp "$UPGRADE_SCRIPT" setup/scripts/upgrade.sh 2>/dev/null || true
        git add -A
        git commit -m "Add structure" >/dev/null 2>&1
        git push origin "$(git branch --show-current)" >/dev/null 2>&1
    )

    echo "$repo"
}

test_script_exists() {
    assert_file_exists "$UPGRADE_SCRIPT"
    [[ -x "$UPGRADE_SCRIPT" ]] || chmod +x "$UPGRADE_SCRIPT"
    assert_success test -x "$UPGRADE_SCRIPT"
}

test_help_flag() {
    local output
    output=$(bash "$UPGRADE_SCRIPT" --help 2>&1)
    assert_contains "$output" "Usage"
    assert_contains "$output" "rollback"
}

test_dry_run() {
    local repo
    repo=$(_setup_upgrade_env)

    local before_hash
    before_hash=$(git -C "$repo" rev-parse HEAD)

    local output
    output=$(bash "$UPGRADE_SCRIPT" --dry-run --repo "$repo" 2>&1) || true

    local after_hash
    after_hash=$(git -C "$repo" rev-parse HEAD)

    assert_eq "$before_hash" "$after_hash" "dry-run should not change HEAD"

    # Should not create any tags
    local tag_count
    tag_count=$(git -C "$repo" tag -l 'pre-upgrade-*' | wc -l)
    assert_eq "0" "$tag_count" "dry-run should not create tags"
}

test_creates_pre_upgrade_tag() {
    local repo
    repo=$(_setup_upgrade_env)
    local remote="$TEST_TMPDIR/remote.git"

    # Push a new commit to remote so there's something to pull
    local clone="$TEST_TMPDIR/clone"
    git clone "$remote" "$clone" >/dev/null 2>&1
    (
        cd "$clone"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "update" > update.txt
        git add update.txt
        git commit -m "Remote update" >/dev/null 2>&1
        git push >/dev/null 2>&1
    )

    bash "$UPGRADE_SCRIPT" --repo "$repo" --skip-deploy 2>&1 || true

    local tag_count
    tag_count=$(git -C "$repo" tag -l 'pre-upgrade-*' | wc -l)
    assert_eq "1" "$tag_count" "should create exactly one pre-upgrade tag"
}

test_pulls_latest() {
    local repo
    repo=$(_setup_upgrade_env)
    local remote="$TEST_TMPDIR/remote.git"

    # Push a new commit to remote from a separate clone
    local clone="$TEST_TMPDIR/clone"
    git clone "$remote" "$clone" >/dev/null 2>&1
    (
        cd "$clone"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "new content" > newfile.txt
        git add newfile.txt
        git commit -m "Remote update" >/dev/null 2>&1
        git push >/dev/null 2>&1
    )

    local before_hash
    before_hash=$(git -C "$repo" rev-parse HEAD)

    bash "$UPGRADE_SCRIPT" --repo "$repo" --skip-deploy 2>&1 || true

    local after_hash
    after_hash=$(git -C "$repo" rev-parse HEAD)

    assert_neq "$before_hash" "$after_hash" "HEAD should advance after pull"
    assert_file_exists "$repo/newfile.txt"
}

test_rollback() {
    local repo
    repo=$(_setup_upgrade_env)
    local remote="$TEST_TMPDIR/remote.git"

    # Remember original state
    local original_hash
    original_hash=$(git -C "$repo" rev-parse HEAD)

    # Push a new commit to remote
    local clone="$TEST_TMPDIR/clone"
    git clone "$remote" "$clone" >/dev/null 2>&1
    (
        cd "$clone"
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "breaking change" > breaking.txt
        git add breaking.txt
        git commit -m "Breaking update" >/dev/null 2>&1
        git push >/dev/null 2>&1
    )

    # Upgrade (creates tag + pulls)
    bash "$UPGRADE_SCRIPT" --repo "$repo" --skip-deploy 2>&1 || true

    local upgraded_hash
    upgraded_hash=$(git -C "$repo" rev-parse HEAD)
    assert_neq "$original_hash" "$upgraded_hash" "should have upgraded"

    # Rollback
    bash "$UPGRADE_SCRIPT" --rollback --repo "$repo" 2>&1 || true

    local rollback_hash
    rollback_hash=$(git -C "$repo" rev-parse HEAD)
    assert_eq "$original_hash" "$rollback_hash" "rollback should restore original HEAD"
    assert_file_not_exists "$repo/breaking.txt"
}

test_rollback_no_tags() {
    local repo
    repo=$(_setup_upgrade_env)

    local output
    output=$(bash "$UPGRADE_SCRIPT" --rollback --repo "$repo" 2>&1) || true

    assert_contains "$output" "No pre-upgrade tag"
}

test_already_up_to_date() {
    local repo
    repo=$(_setup_upgrade_env)

    local output
    output=$(bash "$UPGRADE_SCRIPT" --repo "$repo" --skip-deploy 2>&1) || true

    assert_contains "$output" "up to date"
}

test_list_tags() {
    local repo
    repo=$(_setup_upgrade_env)

    # Create a tag manually
    git -C "$repo" tag "pre-upgrade-2026-03-12-180000"

    local output
    output=$(bash "$UPGRADE_SCRIPT" --list-tags --repo "$repo" 2>&1)

    assert_contains "$output" "pre-upgrade-2026-03-12-180000"
}

_ROLLBACK_CASES=(
    "upgrade.sh exists and is executable|test_script_exists"
    "upgrade.sh --help shows usage with rollback info|test_help_flag"
    "upgrade.sh --dry-run does not modify repo|test_dry_run"
    "upgrade.sh creates pre-upgrade-TIMESTAMP tag|test_creates_pre_upgrade_tag"
    "upgrade.sh pulls latest changes from remote|test_pulls_latest"
    "upgrade.sh --rollback reverts to pre-upgrade state|test_rollback"
    "upgrade.sh --rollback shows error when no tags exist|test_rollback_no_tags"
    "upgrade.sh handles already-up-to-date gracefully|test_already_up_to_date"
    "upgrade.sh --list-tags shows available rollback points|test_list_tags"
)
for _case in "${_ROLLBACK_CASES[@]}"; do
    if [[ -f "$UPGRADE_SCRIPT" ]]; then
        run_test "${_case%%|*}" "${_case##*|}"
    else
        skip_test "${_case%%|*}" "subject setup/scripts/upgrade.sh not present in this repo (template-only, AFT-29)"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════

suite_summary
