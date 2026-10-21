#!/usr/bin/env bash
# Tests for sync.sh setup provisioning steps (CFG-219)
# Verifies that cmd_setup checks and runs VoltAgent install, skill collections install,
# and reports CC version.
source "$(dirname "$0")/test-helpers.sh"

SETUP_LIB="$REPO_ROOT/sync-lib/setup.sh"

suite_header "sync.sh setup — provisioning checks (CFG-219)"

# ── Helper: create a minimal mock environment for setup provisioning tests ────
# We test the provisioning function in isolation, not the full cmd_setup.
_source_provisioning() {
    # Provide stub log functions
    log_info()  { echo "[INFO] $*"; }
    log_warn()  { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
    # Stub portable functions
    _to_native_path() { echo "$1"; }

    # Source the provisioning function from sync-lib/setup.sh
    source <(sed -n '/^run_provisioning_checks()/,/^}/p' "$SETUP_LIB")
}

# ── VoltAgent: missing marketplace triggers install ─────────────────────────

test_setup_detects_missing_voltagent_and_runs_install() {
    # Set up mock environment: no marketplace.json means VoltAgent not installed
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    # No marketplace.json exists

    # Create a mock install-voltagent.sh that just records it was called
    mkdir -p "$TEST_TMPDIR/scripts"
    cat > "$TEST_TMPDIR/scripts/install-voltagent.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "VOLTAGENT_INSTALL_CALLED"
SCRIPT
    chmod +x "$TEST_TMPDIR/scripts/install-voltagent.sh"

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        # Override the script path
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        run_provisioning_checks
    )

    assert_contains "$out" "VOLTAGENT_INSTALL_CALLED"
    assert_contains "$out" "VoltAgent marketplace not found"
}
run_test "setup detects missing VoltAgent and runs install" test_setup_detects_missing_voltagent_and_runs_install

# ── VoltAgent: existing marketplace skips install ───────────────────────────

test_setup_detects_existing_voltagent_and_skips() {
    # Set up mock environment: marketplace.json exists means VoltAgent installed
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    echo '{"name": "voltagent"}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins/marketplace.json"

    # Create a mock install script that should NOT be called
    mkdir -p "$TEST_TMPDIR/scripts"
    cat > "$TEST_TMPDIR/scripts/install-voltagent.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "VOLTAGENT_INSTALL_CALLED_UNEXPECTEDLY"
SCRIPT
    chmod +x "$TEST_TMPDIR/scripts/install-voltagent.sh"

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        run_provisioning_checks
    )

    assert_not_contains "$out" "VOLTAGENT_INSTALL_CALLED_UNEXPECTEDLY"
    assert_contains "$out" "VoltAgent marketplace: installed"
}
run_test "setup detects existing VoltAgent and skips install" test_setup_detects_existing_voltagent_and_skips

# ── Skill collections: missing triggers install ─────────────────────────────

test_setup_detects_missing_skill_collections_and_runs_install() {
    # No skill-collections directory
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    # Ensure VoltAgent exists (so we test skill collections in isolation)
    echo '{}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins/marketplace.json"

    # Create a mock install-skill-collections.sh
    mkdir -p "$TEST_TMPDIR/scripts"
    cat > "$TEST_TMPDIR/scripts/install-skill-collections.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "SKILL_COLLECTIONS_INSTALL_CALLED"
SCRIPT
    chmod +x "$TEST_TMPDIR/scripts/install-skill-collections.sh"

    # Mock voltagent install script too (won't be called but must exist for the function)
    cat > "$TEST_TMPDIR/scripts/install-voltagent.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "VOLTAGENT_INSTALL_CALLED"
SCRIPT
    chmod +x "$TEST_TMPDIR/scripts/install-voltagent.sh"

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        SKILL_COLLECTIONS_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-skill-collections.sh"
        run_provisioning_checks
    )

    assert_contains "$out" "SKILL_COLLECTIONS_INSTALL_CALLED"
    assert_contains "$out" "Skill collections not found"
}
run_test "setup detects missing skill collections and runs install" test_setup_detects_missing_skill_collections_and_runs_install

# ── Skill collections: existing skips install ───────────────────────────────

test_setup_detects_existing_skill_collections_and_skips() {
    # Skill collections directory exists with content
    mkdir -p "$TEST_TMPDIR/.local/share/skill-collections/some-collection/.git"
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    echo '{}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins/marketplace.json"

    mkdir -p "$TEST_TMPDIR/scripts"
    cat > "$TEST_TMPDIR/scripts/install-skill-collections.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "SKILL_COLLECTIONS_INSTALL_CALLED_UNEXPECTEDLY"
SCRIPT
    chmod +x "$TEST_TMPDIR/scripts/install-skill-collections.sh"
    cat > "$TEST_TMPDIR/scripts/install-voltagent.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "SHOULD_NOT_RUN"
SCRIPT
    chmod +x "$TEST_TMPDIR/scripts/install-voltagent.sh"

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        SKILL_COLLECTIONS_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-skill-collections.sh"
        run_provisioning_checks
    )

    assert_not_contains "$out" "SKILL_COLLECTIONS_INSTALL_CALLED_UNEXPECTEDLY"
    assert_contains "$out" "Skill collections: installed"
}
run_test "setup detects existing skill collections and skips install" test_setup_detects_existing_skill_collections_and_skips

# ── CC version: reports version when package.json exists ────────────────────

test_setup_reports_cc_version() {
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    echo '{}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins/marketplace.json"
    mkdir -p "$TEST_TMPDIR/.local/share/skill-collections/some/.git"

    echo '{"version": "2.1.76"}' > "$TEST_TMPDIR/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json"

    mkdir -p "$TEST_TMPDIR/scripts"
    cat > "$TEST_TMPDIR/scripts/install-voltagent.sh" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT
    cat > "$TEST_TMPDIR/scripts/install-skill-collections.sh" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        SKILL_COLLECTIONS_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-skill-collections.sh"
        run_provisioning_checks
    )

    assert_contains "$out" "Claude Code version: 2.1.76"
}
run_test "setup reports CC version from package.json" test_setup_reports_cc_version

# ── CC version: handles missing package.json gracefully ─────────────────────

test_setup_reports_missing_cc_version() {
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    echo '{}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins/marketplace.json"
    mkdir -p "$TEST_TMPDIR/.local/share/skill-collections/some/.git"
    # No package.json at all

    mkdir -p "$TEST_TMPDIR/scripts"
    cat > "$TEST_TMPDIR/scripts/install-voltagent.sh" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT
    cat > "$TEST_TMPDIR/scripts/install-skill-collections.sh" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        SKILL_COLLECTIONS_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-skill-collections.sh"
        run_provisioning_checks
    )

    assert_contains "$out" "Claude Code: not found"
}
run_test "setup handles missing CC package.json gracefully" test_setup_reports_missing_cc_version

# ── Install script missing: warns but doesn't fail ─────────────────────────

test_setup_warns_when_install_script_missing() {
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    # No marketplace.json (needs install) but install script doesn't exist

    local out
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/nonexistent/install-voltagent.sh"
        SKILL_COLLECTIONS_INSTALL_SCRIPT="$TEST_TMPDIR/nonexistent/install-skill-collections.sh"
        run_provisioning_checks
    )

    assert_contains "$out" "install script not found"
}
run_test "setup warns when install script is missing" test_setup_warns_when_install_script_missing

# ── Idempotency: running provisioning twice produces same result ────────────

test_setup_provisioning_is_idempotent() {
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    echo '{}' > "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins/marketplace.json"
    mkdir -p "$TEST_TMPDIR/.local/share/skill-collections/some/.git"
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    echo '{"version": "2.1.76"}' > "$TEST_TMPDIR/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json"

    mkdir -p "$TEST_TMPDIR/scripts"
    cat > "$TEST_TMPDIR/scripts/install-voltagent.sh" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT
    cat > "$TEST_TMPDIR/scripts/install-skill-collections.sh" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT

    # Run twice
    local out1 out2
    out1=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        SKILL_COLLECTIONS_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-skill-collections.sh"
        run_provisioning_checks
    )
    out2=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        SKILL_COLLECTIONS_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-skill-collections.sh"
        run_provisioning_checks
    )

    # Both runs should produce identical output (all "already installed")
    assert_eq "$out1" "$out2" "provisioning should be idempotent"
}
run_test "provisioning checks are idempotent" test_setup_provisioning_is_idempotent

# ── VoltAgent install failure: doesn't block setup ──────────────────────────

test_setup_continues_when_voltagent_install_fails() {
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/config/plugins"
    # No marketplace.json — needs install
    mkdir -p "$TEST_TMPDIR/.local/share/skill-collections/some/.git"
    mkdir -p "$TEST_TMPDIR/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    echo '{"version": "2.1.76"}' > "$TEST_TMPDIR/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json"

    # Create a mock install script that FAILS
    mkdir -p "$TEST_TMPDIR/scripts"
    cat > "$TEST_TMPDIR/scripts/install-voltagent.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "VOLTAGENT_INSTALL_ATTEMPTED"
exit 1
SCRIPT
    chmod +x "$TEST_TMPDIR/scripts/install-voltagent.sh"
    cat > "$TEST_TMPDIR/scripts/install-skill-collections.sh" << 'SCRIPT'
#!/usr/bin/env bash
SCRIPT

    local out rc=0
    out=$(
        HOME="$TEST_TMPDIR"
        CC_MIRROR_DIR="$TEST_TMPDIR/.cc-mirror/mclaude"
        SCRIPT_DIR="$TEST_TMPDIR"
        _source_provisioning
        VOLTAGENT_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-voltagent.sh"
        SKILL_COLLECTIONS_INSTALL_SCRIPT="$TEST_TMPDIR/scripts/install-skill-collections.sh"
        run_provisioning_checks
    ) || rc=$?

    # Should not fail overall
    assert_eq "0" "$rc" "provisioning should not fail when install fails"
    assert_contains "$out" "VOLTAGENT_INSTALL_ATTEMPTED"
    assert_contains "$out" "install failed"
    # Should still report CC version (continues past failure)
    assert_contains "$out" "Claude Code version: 2.1.76"
}
run_test "setup continues when VoltAgent install fails" test_setup_continues_when_voltagent_install_fails

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
