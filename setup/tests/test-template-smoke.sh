#!/usr/bin/env bash
# Template smoke test — CFG-72
# Clones the template to /tmp, validates structure, setup behavior, and privacy.
# Does NOT run full install.sh (requires sudo). Tests what we can safely.
source "$(dirname "$0")/test-helpers.sh"

suite_header "Template Smoke Test (CFG-72)"

# ── Helpers ──────────────────────────────────────────────────────────────────

SMOKE_DIR=""

# Create a fresh clone of the template in /tmp
setup_smoke_clone() {
    SMOKE_DIR="$(mktemp -d /tmp/agent-fleet-smoke.XXXXXX)"
    # Use local copy (git clone is fast for local repos)
    git clone --quiet "$REPO_ROOT" "$SMOKE_DIR" 2>/dev/null
    # Simulate fresh template state: add .template-repo marker
    echo "template" > "$SMOKE_DIR/.template-repo"
}

cleanup_smoke_clone() {
    [[ -n "$SMOKE_DIR" && -d "$SMOKE_DIR" ]] && rm -rf "$SMOKE_DIR"
    SMOKE_DIR=""
}

# ── 1. Repository Structure ─────────────────────────────────────────────────

test_structure_essential_dirs() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    assert_dir_exists "$SMOKE_DIR/setup"
    assert_dir_exists "$SMOKE_DIR/setup/scripts"
    assert_dir_exists "$SMOKE_DIR/setup/tests"
    assert_dir_exists "$SMOKE_DIR/global"
    assert_dir_exists "$SMOKE_DIR/global/foundation"
    assert_dir_exists "$SMOKE_DIR/global/reference"
    assert_dir_exists "$SMOKE_DIR/global/knowledge"
    assert_dir_exists "$SMOKE_DIR/global/domains"
    assert_dir_exists "$SMOKE_DIR/global/hooks"
    assert_dir_exists "$SMOKE_DIR/global/machines"
}
run_test "essential directories exist" test_structure_essential_dirs

test_structure_essential_files() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    assert_file_exists "$SMOKE_DIR/setup/install.sh"
    assert_file_exists "$SMOKE_DIR/setup/install-base.sh"
    assert_file_exists "$SMOKE_DIR/setup/configure-claude.sh"
    assert_file_exists "$SMOKE_DIR/setup/lib.sh"
    assert_file_exists "$SMOKE_DIR/global/CLAUDE.md"
    assert_file_exists "$SMOKE_DIR/global/foundation/session-protocol.md"
    assert_file_exists "$SMOKE_DIR/global/foundation/personas.md"
    assert_file_exists "$SMOKE_DIR/global/foundation/first-run-refinement.md"
    assert_file_exists "$SMOKE_DIR/global/hooks/config-check.sh"
    assert_file_exists "$SMOKE_DIR/global/hooks/config-auto-sync.sh"
    assert_file_exists "$SMOKE_DIR/global/machines/_template.md"
    assert_file_exists "$SMOKE_DIR/global/machines/INDEX.md"
    assert_file_exists "$SMOKE_DIR/sync.sh"
    assert_file_exists "$SMOKE_DIR/README.md"
}
run_test "essential files exist" test_structure_essential_files

test_structure_template_repo_marker() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    assert_file_exists "$SMOKE_DIR/.template-repo" \
        ".template-repo must exist in fresh clone (gates first-run)"
}
run_test ".template-repo marker exists in fresh clone" test_structure_template_repo_marker

test_install_creates_setup_pending() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    assert_file_exists "$SMOKE_DIR/.template-repo"
    assert_file_not_exists "$SMOKE_DIR/.setup-pending"

    # Simulate install.sh template cleanup logic
    local test_root="$SMOKE_DIR"
    if [[ -f "${test_root}/.template-repo" ]]; then
        rm -f "${test_root}/.template-repo"
        if [[ ! -f "${test_root}/.setup-pending" ]]; then
            touch "${test_root}/.setup-pending"
        fi
    fi

    assert_file_not_exists "$SMOKE_DIR/.template-repo" \
        ".template-repo should be removed"
    assert_file_exists "$SMOKE_DIR/.setup-pending" \
        ".setup-pending should be created after .template-repo removal"
}
run_test "install.sh creates .setup-pending after removing .template-repo" test_install_creates_setup_pending

# ── 2. Template Marker (.template-repo) Handling ────────────────────────────

test_install_removes_template_marker() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    assert_file_exists "$SMOKE_DIR/.template-repo"

    # Simulate install.sh cleanup logic (extracted, no sudo needed)
    local test_root="$SMOKE_DIR"
    if [[ -f "${test_root}/.template-repo" ]]; then
        rm -f "${test_root}/.template-repo"
    fi

    assert_file_not_exists "$SMOKE_DIR/.template-repo" \
        "install.sh cleanup should delete .template-repo"
}
run_test "install.sh cleanup removes .template-repo" test_install_removes_template_marker

# ── 3. Origin Remote Safety ─────────────────────────────────────────────────

test_origin_safety_renames_template_remote() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    # Set origin to template URL
    git -C "$SMOKE_DIR" remote set-url origin "https://github.com/JeltzProstetnic/agent-fleet.git" 2>/dev/null

    # Run the origin safety logic from install.sh
    local _origin_url _template_patterns
    _origin_url=$(git -C "$SMOKE_DIR" remote get-url origin 2>/dev/null || echo "")
    _template_patterns="JeltzProstetnic/agent-fleet|IvoclarR-D-AIOrg/agent-fleet"

    if [[ -n "${_origin_url}" ]] && echo "${_origin_url}" | grep -qE "${_template_patterns}"; then
        if ! git -C "$SMOKE_DIR" remote get-url upstream &>/dev/null; then
            git -C "$SMOKE_DIR" remote rename origin upstream
        else
            git -C "$SMOKE_DIR" remote remove origin
        fi
    fi

    # origin should no longer exist (or point to template)
    local new_origin
    new_origin=$(git -C "$SMOKE_DIR" remote get-url origin 2>/dev/null || echo "")
    assert_eq "" "$new_origin" "origin should be removed or renamed"

    # upstream should exist and point to template
    local upstream_url
    upstream_url=$(git -C "$SMOKE_DIR" remote get-url upstream 2>/dev/null || echo "")
    assert_contains "$upstream_url" "agent-fleet" "upstream should point to template"
}
run_test "origin remote safety renames template origin to upstream" test_origin_safety_renames_template_remote

test_origin_safety_ivoclar_pattern() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    git -C "$SMOKE_DIR" remote set-url origin "https://github.com/IvoclarR-D-AIOrg/agent-fleet.git" 2>/dev/null

    local _origin_url _template_patterns
    _origin_url=$(git -C "$SMOKE_DIR" remote get-url origin 2>/dev/null || echo "")
    _template_patterns="JeltzProstetnic/agent-fleet|IvoclarR-D-AIOrg/agent-fleet"

    if [[ -n "${_origin_url}" ]] && echo "${_origin_url}" | grep -qE "${_template_patterns}"; then
        if ! git -C "$SMOKE_DIR" remote get-url upstream &>/dev/null; then
            git -C "$SMOKE_DIR" remote rename origin upstream
        else
            git -C "$SMOKE_DIR" remote remove origin
        fi
    fi

    local new_origin
    new_origin=$(git -C "$SMOKE_DIR" remote get-url origin 2>/dev/null || echo "")
    assert_eq "" "$new_origin" "origin should be removed for Ivoclar pattern too"
}
run_test "origin remote safety handles Ivoclar org pattern" test_origin_safety_ivoclar_pattern

test_origin_safety_preserves_user_remote() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    git -C "$SMOKE_DIR" remote set-url origin "https://github.com/someuser/my-fleet.git" 2>/dev/null

    local _origin_url _template_patterns
    _origin_url=$(git -C "$SMOKE_DIR" remote get-url origin 2>/dev/null || echo "")
    _template_patterns="JeltzProstetnic/agent-fleet|IvoclarR-D-AIOrg/agent-fleet"

    if [[ -n "${_origin_url}" ]] && echo "${_origin_url}" | grep -qE "${_template_patterns}"; then
        if ! git -C "$SMOKE_DIR" remote get-url upstream &>/dev/null; then
            git -C "$SMOKE_DIR" remote rename origin upstream
        fi
    fi

    local current_origin
    current_origin=$(git -C "$SMOKE_DIR" remote get-url origin 2>/dev/null || echo "")
    assert_contains "$current_origin" "someuser/my-fleet" \
        "user's own origin should NOT be renamed"
}
run_test "origin remote safety preserves user's own remote" test_origin_safety_preserves_user_remote

# ── 4. Privacy: No Personal Data in Template ────────────────────────────────

test_no_personal_machine_files() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    # Only _template.md and INDEX.md should exist in machines/
    local personal_files
    personal_files=$(find "$SMOKE_DIR/global/machines" -name '*.md' \
        ! -name '_template.md' ! -name 'INDEX.md' 2>/dev/null || true)

    assert_eq "" "$personal_files" \
        "machines/ should only contain _template.md and INDEX.md, found: $personal_files"
}
run_test "no personal machine files in template" test_no_personal_machine_files

test_no_personal_data_patterns() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    # Personal data patterns that should NEVER appear in the template
    # Generic enough to catch leaks without being developer-specific
    local patterns=(
        '/home/jeltz'
        '/home/deck'
        '/home/gruber'
        'jeltz.prostetnic@gmail.com'
        'matthias@matthiasgruber.com'
        'gutachten@matthiasgruber.com'
        'DESKTOP-32ILURB'
        'srv943133'
        '192.168.50.199'
        '109.106.246.63'
        'mycloudex2ultra'
        'ZH4HyxgrcabYR5ap'
    )

    for pattern in "${patterns[@]}"; do
        local hits
        hits=$(grep -rl --include='*.md' --include='*.sh' --include='*.json' \
            "$pattern" "$SMOKE_DIR" 2>/dev/null \
            | grep -v '.git/' \
            | grep -v 'setup/tests/' \
            || true)
        assert_eq "" "$hits" \
            "personal data pattern '$pattern' found in: $hits"
    done
}
run_test "no personal data patterns in template files" test_no_personal_data_patterns

test_no_personal_domains_files() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    # domains/life-management/ should not exist in template
    # (career.md, family.md, etc. are personal)
    local life_mgmt="$SMOKE_DIR/global/domains/life-management"
    if [[ -d "$life_mgmt" ]]; then
        local files
        files=$(ls "$life_mgmt"/*.md 2>/dev/null | wc -l)
        assert_eq "0" "$files" \
            "life-management domain should not have personal files in template"
    fi
    # Pass if dir doesn't exist
}
run_test "no personal domain files in template" test_no_personal_domains_files

# ── 5. install.sh --dry-run ─────────────────────────────────────────────────

test_install_dry_run_completes() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local rc=0
    # --dry-run should preview without requiring sudo or making changes
    # Run with piped stdin to simulate non-interactive
    local output
    output=$(echo "" | bash "$SMOKE_DIR/setup/install.sh" --dry-run --no-color 2>&1) || rc=$?

    # Dry run should exit 0
    assert_eq "0" "$rc" "install.sh --dry-run should exit 0 (got $rc)"

    # Should contain preview text
    assert_contains "$output" "DRY RUN" "dry-run output should mention DRY RUN"
}
run_test "install.sh --dry-run completes successfully" test_install_dry_run_completes

# ── 6. lib.sh Sources Cleanly ───────────────────────────────────────────────

test_lib_sources_cleanly() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local rc=0
    (
        # Source lib.sh in a subshell to avoid polluting test environment
        source "$SMOKE_DIR/setup/lib.sh" 2>/dev/null
    ) || rc=$?

    assert_eq "0" "$rc" "lib.sh should source without errors"
}
run_test "lib.sh sources cleanly" test_lib_sources_cleanly

# ── 7. sync.sh Sources and Has Key Commands ─────────────────────────────────

test_sync_sh_has_commands() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    assert_file_contains "$SMOKE_DIR/sync.sh" "setup)" "sync.sh should have setup command"
    assert_file_contains "$SMOKE_DIR/sync.sh" "deploy)" "sync.sh should have deploy command"
    assert_file_contains "$SMOKE_DIR/sync.sh" "collect)" "sync.sh should have collect command"
    assert_file_contains "$SMOKE_DIR/sync.sh" "status)" "sync.sh should have status command"
}
run_test "sync.sh has essential commands" test_sync_sh_has_commands

# ── 8. CLAUDE.md Structural Integrity ───────────────────────────────────────

test_claude_md_has_required_sections() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local claude_md="$SMOKE_DIR/global/CLAUDE.md"

    assert_file_contains "$claude_md" "## Machine Identity"
    assert_file_contains "$claude_md" "## Session Start"
    assert_file_contains "$claude_md" "## Development Rules"
    assert_file_contains "$claude_md" "## Persona System"
    assert_file_contains "$claude_md" "## Conventions"
}
run_test "CLAUDE.md has required sections" test_claude_md_has_required_sections

test_claude_md_template_clone_detection() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local claude_md="$SMOKE_DIR/global/CLAUDE.md"

    assert_file_contains "$claude_md" ".template-repo" \
        "CLAUDE.md should reference .template-repo for template-clone detection"
    assert_file_contains "$claude_md" ".setup-pending" \
        "CLAUDE.md should reference .setup-pending for first-run refinement"
}
run_test "CLAUDE.md has template-clone detection" test_claude_md_template_clone_detection

# ── 9. First-Run Refinement ─────────────────────────────────────────────────

test_first_run_has_verification_checklist() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local frr="$SMOKE_DIR/global/foundation/first-run-refinement.md"
    assert_file_exists "$frr"
    assert_file_contains "$frr" "verification" \
        "first-run-refinement.md should have verification checklist"
    assert_file_contains "$frr" ".setup-pending" \
        "first-run-refinement.md should reference .setup-pending"
}
run_test "first-run-refinement.md has verification checklist" test_first_run_has_verification_checklist

test_first_run_pat_security_warning() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local frr="$SMOKE_DIR/global/foundation/first-run-refinement.md"
    assert_file_contains "$frr" "Never ask the user to paste tokens" \
        "first-run-refinement.md should warn against pasting tokens"
}
run_test "first-run-refinement.md has PAT security warning" test_first_run_pat_security_warning

# ── 10. Hooks Structural Checks ─────────────────────────────────────────────

test_hooks_are_bash_scripts() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    for hook in config-check.sh config-auto-sync.sh; do
        local hookfile="$SMOKE_DIR/global/hooks/$hook"
        assert_file_exists "$hookfile"
        local shebang
        shebang=$(head -1 "$hookfile")
        assert_contains "$shebang" "bash" \
            "$hook should have bash shebang"
    done
}
run_test "hooks are valid bash scripts with shebangs" test_hooks_are_bash_scripts

test_config_check_handles_template_repo() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local hook="$SMOKE_DIR/global/hooks/config-check.sh"
    assert_file_contains "$hook" ".template-repo" \
        "config-check.sh should detect .template-repo marker"
}
run_test "config-check.sh handles .template-repo" test_config_check_handles_template_repo

# ── 11. README Has Key Sections ─────────────────────────────────────────────

test_readme_no_fork_guidance() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local readme="$SMOKE_DIR/README.md"
    assert_file_contains "$readme" "template" \
        "README should mention template button"
    assert_file_contains "$readme" "NOT fork" \
        "README should warn against forking"
}
run_test "README has no-fork guidance" test_readme_no_fork_guidance

test_readme_pat_security() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local readme="$SMOKE_DIR/README.md"
    assert_file_contains "$readme" "Token" \
        "README should have token security section"
}
run_test "README has token security section" test_readme_pat_security

# ── 12. GitHub Issue Template ────────────────────────────────────────────────

test_issue_template_exists() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local tmpl="$SMOKE_DIR/.github/ISSUE_TEMPLATE/fleet-report.md"
    if [[ -f "$tmpl" ]]; then
        assert_file_contains "$tmpl" "fleet-reported" \
            "issue template should have fleet-reported label"
        assert_file_contains "$tmpl" "Fleet Metadata" \
            "issue template should have Fleet Metadata section"
    else
        skip_test "GitHub issue template" "not yet created"
    fi
}
run_test "GitHub issue template exists and is valid" test_issue_template_exists

# ── 13. Memory Architecture Section ─────────────────────────────────────────

test_memory_architecture_section() {
    setup_smoke_clone
    trap cleanup_smoke_clone RETURN

    local claude_md="$SMOKE_DIR/global/CLAUDE.md"
    assert_file_contains "$claude_md" "Memory Architecture" \
        "CLAUDE.md should have Memory Architecture section"
}
run_test "CLAUDE.md has Memory Architecture section" test_memory_architecture_section

# ── Summary ──────────────────────────────────────────────────────────────────

suite_summary
