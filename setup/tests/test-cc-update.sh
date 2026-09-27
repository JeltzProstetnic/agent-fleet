#!/usr/bin/env bash
# Tests for setup/scripts/cc-update.sh — Claude Code update script
# TDD: tests written first, implementation makes them pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

CC_UPDATE="$REPO_ROOT/setup/scripts/cc-update.sh"

suite_header "cc-update.sh"

# ── Sandbox helper ──────────────────────────────────────────────────────────

# Creates a realistic cc-mirror sandbox structure in $HOME.
# After calling this, the sandbox looks like:
#   $HOME/.cc-mirror/mclaude/
#     npm/node_modules/@anthropic-ai/claude-code/
#       package.json   (version: 2.1.111)
#       cli.js         (dummy executable)
#     variant.json
#     tweakcc/config.json
#   $HOME/.local/bin/
#     mclaude          (launcher with exec node ... cli.js)
create_cc_mirror_sandbox() {
    local version="${1:-2.1.111}"
    local mirror_root="$HOME/.cc-mirror/mclaude"
    local pkg_dir="$mirror_root/npm/node_modules/@anthropic-ai/claude-code"

    mkdir -p "$pkg_dir/bin"
    mkdir -p "$mirror_root/tweakcc"
    mkdir -p "$HOME/.local/bin"

    # package.json
    cat > "$pkg_dir/package.json" << PKGEOF
{
  "name": "@anthropic-ai/claude-code",
  "version": "$version"
}
PKGEOF

    # cli.js — dummy legacy entry point
    cat > "$pkg_dir/cli.js" << 'CLIEOF'
#!/usr/bin/env node
console.log("2.1.111 (Claude Code)");
CLIEOF
    chmod +x "$pkg_dir/cli.js"

    # variant.json
    cat > "$mirror_root/variant.json" << VAREOF
{
  "name": "mclaude",
  "provider": "mirror",
  "binaryPath": "$pkg_dir/cli.js",
  "configDir": "$mirror_root/config",
  "tweakDir": "$mirror_root/tweakcc",
  "installType": "npm",
  "npmDir": "$mirror_root/npm",
  "npmPackage": "@anthropic-ai/claude-code",
  "npmVersion": "$version",
  "updatedAt": "2026-01-01T00:00:00.000Z"
}
VAREOF

    # tweakcc config
    cat > "$mirror_root/tweakcc/config.json" << 'TWEOF'
{
  "patches": []
}
TWEOF

    # Launcher script
    cat > "$HOME/.local/bin/mclaude" << LAUNCHEOF
#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_CONFIG_DIR="$mirror_root/config"
export TWEAKCC_CONFIG_DIR="$mirror_root/tweakcc"
# Run Claude Code
exec node "$pkg_dir/cli.js" "\$@"
LAUNCHEOF
    chmod +x "$HOME/.local/bin/mclaude"
}

# Add a native binary entry point (bin/claude.exe) to the sandbox.
# Simulates a post-2.2 package that ships a native binary.
add_native_binary() {
    local pkg_dir="$HOME/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$pkg_dir/bin/claude.exe" << 'BINEOF'
#!/bin/sh
echo "claude native binary stub"
BINEOF
    chmod +x "$pkg_dir/bin/claude.exe"
}

# Add bin/claude (no .exe) to simulate a Linux native binary
add_native_binary_linux() {
    local pkg_dir="$HOME/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"
    cat > "$pkg_dir/bin/claude" << 'BINEOF'
#!/bin/sh
echo "claude native binary stub"
BINEOF
    chmod +x "$pkg_dir/bin/claude"
}

# Install a mock npm binary that simulates a successful install by
# updating package.json to the target version and optionally adding a native binary.
# This gets called BY the script during Phase 2, not before.
setup_mock_npm() {
    local target_version="$1"
    local add_binary="${2:-true}"
    local pkg_dir="$HOME/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code"

    mkdir -p "$TEST_TMPDIR/mockbin"
    cat > "$TEST_TMPDIR/mockbin/npm" << NPMEOF
#!/bin/sh
# Mock npm: update package.json to target version
cat > "$pkg_dir/package.json" << INNER
{
  "name": "@anthropic-ai/claude-code",
  "version": "$target_version"
}
INNER
NPMEOF
    if [[ "$add_binary" == "true" ]]; then
        cat >> "$TEST_TMPDIR/mockbin/npm" << NPMEOF2
# Add native binary
mkdir -p "$pkg_dir/bin"
printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$target_version" > "$pkg_dir/bin/claude.exe"
chmod +x "$pkg_dir/bin/claude.exe"
NPMEOF2
    fi
    chmod +x "$TEST_TMPDIR/mockbin/npm"
    export PATH="$TEST_TMPDIR/mockbin:$PATH"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 1: Refuses to run inside Claude Code
# ══════════════════════════════════════════════════════════════════════════════

test_refuses_inside_cc() {
    create_cc_mirror_sandbox

    export CLAUDE_CONFIG_DIR="$HOME/.cc-mirror/mclaude/config"
    local output rc=0
    output=$(bash "$CC_UPDATE" --skip-npm 2>&1) || rc=$?

    assert_neq "0" "$rc" "should exit non-zero when CLAUDE_CONFIG_DIR is set"
    assert_contains "$output" "inside" "should mention running inside CC"
}
run_test "refuses to run inside Claude Code" test_refuses_inside_cc

# ══════════════════════════════════════════════════════════════════════════════
# TEST 2: Detects current version from package.json
# ══════════════════════════════════════════════════════════════════════════════

test_detects_current_version() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    local output
    output=$(bash "$CC_UPDATE" --dry-run --skip-npm 2>&1) || true

    assert_contains "$output" "2.1.111" "should detect and display current version"
}
run_test "detects current version from package.json" test_detects_current_version

# ══════════════════════════════════════════════════════════════════════════════
# TEST 3: Dry run makes no changes
# ══════════════════════════════════════════════════════════════════════════════

test_dry_run_no_changes() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    # Snapshot files before
    local launcher_before variant_before pkg_before
    launcher_before=$(cat "$HOME/.local/bin/mclaude")
    variant_before=$(cat "$HOME/.cc-mirror/mclaude/variant.json")
    pkg_before=$(cat "$HOME/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json")

    local output
    output=$(bash "$CC_UPDATE" --dry-run --version 2.2.0 --skip-npm 2>&1) || true

    # All files unchanged
    local launcher_after variant_after pkg_after
    launcher_after=$(cat "$HOME/.local/bin/mclaude")
    variant_after=$(cat "$HOME/.cc-mirror/mclaude/variant.json")
    pkg_after=$(cat "$HOME/.cc-mirror/mclaude/npm/node_modules/@anthropic-ai/claude-code/package.json")

    assert_eq "$launcher_before" "$launcher_after" "launcher unchanged in dry run"
    assert_eq "$variant_before" "$variant_after" "variant.json unchanged in dry run"
    assert_eq "$pkg_before" "$pkg_after" "package.json unchanged in dry run"
    assert_contains "$output" "dry" "should indicate dry run mode"
}
run_test "dry run makes no changes" test_dry_run_no_changes

# ══════════════════════════════════════════════════════════════════════════════
# TEST 4: Creates backups before updating
# ══════════════════════════════════════════════════════════════════════════════

test_creates_backups() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    setup_mock_npm "2.2.0"

    bash "$CC_UPDATE" --version 2.2.0 2>&1 || true

    assert_file_exists "$HOME/.local/bin/mclaude-backup-2.1.111" \
        "launcher backup should exist with version suffix"
    assert_file_exists "$HOME/.cc-mirror/mclaude/variant.json-backup-2.1.111" \
        "variant.json backup should exist with version suffix"
}
run_test "creates backups with version suffix" test_creates_backups

# ══════════════════════════════════════════════════════════════════════════════
# TEST 5: Detects native binary (bin/claude.exe)
# ══════════════════════════════════════════════════════════════════════════════

test_detects_native_binary() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    add_native_binary

    local output
    output=$(bash "$CC_UPDATE" --dry-run --version 2.2.0 2>&1) || true

    assert_contains "$output" "claude.exe" "should detect bin/claude.exe"
}
run_test "detects native binary (bin/claude.exe)" test_detects_native_binary

# ══════════════════════════════════════════════════════════════════════════════
# TEST 6: Detects legacy cli.js entry point
# ══════════════════════════════════════════════════════════════════════════════

test_detects_legacy_cli() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    local output
    output=$(bash "$CC_UPDATE" --dry-run --version 2.2.0 2>&1) || true

    assert_contains "$output" "cli.js" "should detect cli.js as legacy entry point"
}
run_test "detects legacy cli.js entry point" test_detects_legacy_cli

# ══════════════════════════════════════════════════════════════════════════════
# TEST 7: Updates launcher exec line to native binary
# ══════════════════════════════════════════════════════════════════════════════

test_updates_launcher_exec_line() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    setup_mock_npm "2.2.0"

    bash "$CC_UPDATE" --version 2.2.0 2>&1 || true

    local launcher="$HOME/.local/bin/mclaude"
    local last_line
    last_line=$(tail -1 "$launcher")

    # Last line should now exec the native binary, not node + cli.js
    assert_contains "$last_line" "claude.exe" "last line should reference claude.exe"
    assert_contains "$last_line" "exec" "last line should still use exec"
    assert_not_contains "$last_line" "cli.js" "last line should NOT reference cli.js"
}
run_test "updates launcher exec line to native binary" test_updates_launcher_exec_line

# ══════════════════════════════════════════════════════════════════════════════
# TEST 8: Launcher preserves header (everything before exec line)
# ══════════════════════════════════════════════════════════════════════════════

test_launcher_preserves_header() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    local launcher="$HOME/.local/bin/mclaude"
    local header_before
    header_before=$(head -n -1 "$launcher")

    setup_mock_npm "2.2.0"

    bash "$CC_UPDATE" --version 2.2.0 2>&1 || true

    local header_after
    header_after=$(head -n -1 "$launcher")

    assert_eq "$header_before" "$header_after" "launcher header should be preserved"
}
run_test "launcher preserves header (before exec line)" test_launcher_preserves_header

# ══════════════════════════════════════════════════════════════════════════════
# TEST 9: Updates variant.json fields
# ══════════════════════════════════════════════════════════════════════════════

test_updates_variant_json() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    setup_mock_npm "2.2.0"

    bash "$CC_UPDATE" --version 2.2.0 2>&1 || true

    local variant="$HOME/.cc-mirror/mclaude/variant.json"
    assert_file_contains "$variant" '"npmVersion"' "variant.json should have npmVersion"
    assert_file_contains "$variant" '2.2.0' "variant.json should contain new version"
    assert_file_contains "$variant" 'claude.exe' "variant.json binaryPath should reference native binary"
    assert_file_not_contains "$variant" '2.1.111' "variant.json should not contain old version"
}
run_test "updates variant.json (binaryPath, npmVersion)" test_updates_variant_json

# ══════════════════════════════════════════════════════════════════════════════
# TEST 10: Rollback instructions shown in output
# ══════════════════════════════════════════════════════════════════════════════

test_rollback_instructions_shown() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    setup_mock_npm "2.2.0"

    local output
    output=$(bash "$CC_UPDATE" --version 2.2.0 2>&1) || true

    assert_contains "$output" "Rollback" "output should contain rollback instructions"
    assert_contains "$output" "2.1.111" "rollback should reference the old version"
}
run_test "rollback instructions shown in output" test_rollback_instructions_shown

# ══════════════════════════════════════════════════════════════════════════════
# TEST 11: --skip-npm skips the npm install step
# ══════════════════════════════════════════════════════════════════════════════

test_skip_npm_flag() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    # Override npm to track whether it was called
    local npm_marker="$TEST_TMPDIR/npm_was_called"
    export PATH="$TEST_TMPDIR/mockbin:$PATH"
    mkdir -p "$TEST_TMPDIR/mockbin"
    cat > "$TEST_TMPDIR/mockbin/npm" << NPMEOF
#!/bin/sh
touch "$npm_marker"
NPMEOF
    chmod +x "$TEST_TMPDIR/mockbin/npm"

    bash "$CC_UPDATE" --skip-npm --dry-run --version 2.2.0 2>&1 || true

    assert_file_not_exists "$npm_marker" "npm should not be called with --skip-npm"
}
run_test "--skip-npm skips npm install" test_skip_npm_flag

# ══════════════════════════════════════════════════════════════════════════════
# TEST 12: Already up to date exits cleanly
# ══════════════════════════════════════════════════════════════════════════════

test_already_up_to_date() {
    create_cc_mirror_sandbox "2.2.0"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true

    local output rc=0
    output=$(bash "$CC_UPDATE" --skip-npm --version 2.2.0 2>&1) || rc=$?

    assert_eq "0" "$rc" "should exit 0 when already up to date"
    assert_contains "$output" "up to date" "should indicate already up to date"
}
run_test "already up to date exits 0 with message" test_already_up_to_date

# ══════════════════════════════════════════════════════════════════════════════
# TEST 13: claudeOrig pin is rewritten to the installed version (added 2026-09-23)
# ══════════════════════════════════════════════════════════════════════════════
# Measured 2026-09-23: claudeOrig had read `…@2.1.1` since 2026-02-09 in every backup —
# cc-update.sh never touched it — so a cc-mirror re-provision reinstalled 2.1.1 over
# 2.1.274 deterministically. The pin must follow every verified update.

test_rewrites_claude_orig_pin() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    python3 - "$HOME/.cc-mirror/mclaude/variant.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["claudeOrig"] = "npm:@anthropic-ai/claude-code@2.1.1"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
    setup_mock_npm "2.2.0"
    bash "$CC_UPDATE" --version 2.2.0 2>&1 || true
    local orig
    orig=$(grep -o '"claudeOrig": *"[^"]*"' "$HOME/.cc-mirror/mclaude/variant.json" || echo "<absent>")
    echo "    measured claudeOrig after update: [$orig]"
    assert_contains "$orig" "@2.2.0" "claudeOrig must carry the installed version" || return 1
    assert_not_contains "$orig" "2.1.1" "the creation-time pin must be gone"
}
run_test "rewrites variant.json claudeOrig to the installed version" test_rewrites_claude_orig_pin

# ══════════════════════════════════════════════════════════════════════════════
# TEST 14: update-checker is wired into the launcher when the fleet repo exists
# ══════════════════════════════════════════════════════════════════════════════
# Measured 2026-09-23: the live launcher contained ZERO references to update-checker.sh
# and its daily marker read 2026-02-09 — the checker had never run. Test 8 proves the
# header is untouched when no repo exists under $HOME; this proves the wiring when it does.

test_wires_update_checker_when_repo_present() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    mkdir -p "$HOME/cfg-agent-fleet/setup/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/cfg-agent-fleet/setup/scripts/update-checker.sh"
    setup_mock_npm "2.2.0"
    bash "$CC_UPDATE" --version 2.2.0 2>&1 || true
    local launcher="$HOME/.local/bin/mclaude" line_no exec_no
    line_no=$(grep -n 'update-checker.sh' "$launcher" | head -1 | cut -d: -f1 || true)
    exec_no=$(grep -n '^exec ' "$launcher" | tail -1 | cut -d: -f1 || true)
    echo "    measured: update-checker at line ${line_no:-<none>}, exec at line ${exec_no:-<none>}"
    [[ -n "$line_no" ]] || { echo "    launcher does not invoke update-checker.sh" >&2; return 1; }
    [[ "$line_no" -lt "$exec_no" ]] || { echo "    update-checker must run BEFORE exec" >&2; return 1; }
    assert_contains "$(tail -1 "$launcher")" "exec" "exec must remain the last line" || return 1
    # A second update on the SAME install must not wire it twice
    setup_mock_npm "2.3.0"
    bash "$CC_UPDATE" --version 2.3.0 >/dev/null 2>&1 || true
    echo "    measured after second update: $(grep -c 'update-checker.sh' "$launcher") invocation line(s), exec target $(tail -1 "$launcher" | cut -c1-60)"
    assert_eq "1" "$(grep -c 'update-checker.sh' "$launcher")" "wiring must be idempotent (one invocation line)"
}
run_test "wires update-checker.sh into the launcher before exec (idempotent)" test_wires_update_checker_when_repo_present

# ══════════════════════════════════════════════════════════════════════════════

# ── Native-layout sandbox (Deck / NUC: no npm/ tree, one binary) ─────────────

create_native_sandbox() {
    local version="${1:-2.1.113}"
    local mirror_root="$HOME/.cc-mirror/mclaude"
    mkdir -p "$mirror_root/native" "$mirror_root/tweakcc" "$HOME/.local/bin"
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$version" > "$mirror_root/native/claude"
    chmod +x "$mirror_root/native/claude"
    cat > "$mirror_root/variant.json" << VAREOF
{
  "name": "mclaude",
  "provider": "mirror",
  "binaryPath": "$mirror_root/native/claude",
  "configDir": "$mirror_root/config",
  "tweakDir": "$mirror_root/tweakcc",
  "installType": "native",
  "claudeOrig": "native:$version",
  "updatedAt": "2026-01-01T00:00:00.000Z"
}
VAREOF
    printf '{\n  "patches": []\n}\n' > "$mirror_root/tweakcc/config.json"
    cat > "$HOME/.local/bin/mclaude" << LAUNCHEOF
#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_CONFIG_DIR="$mirror_root/config"
exec "$mirror_root/native/claude" "\$@"
LAUNCHEOF
    chmod +x "$HOME/.local/bin/mclaude"
}

# A stand-in for the ELF shipped in the npm tarball: reports <version> on --version.
make_stub_binary() {  # <path> <version>
    printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$2" > "$1"
    chmod +x "$1"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 15: --via binary refuses without a usable source binary
# ══════════════════════════════════════════════════════════════════════════════
# The binary road exists because BOTH Decks have no node and no npx on PATH
# (measured 2026-09-23: `bash -lc 'command -v node'` empty on deck and deck2),
# so the --via cc-mirror road cannot run there at all.

test_binary_requires_source() {
    create_native_sandbox "2.1.113"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    local out rc=0
    out=$(bash "$CC_UPDATE" --via binary --version 2.1.280 2>&1) || rc=$?
    echo "    measured rc=$rc out=$(printf '%s' "$out" | tail -1 | cut -c1-90)"
    [[ "$rc" -ne 0 ]] || { echo "    must refuse when --binary is absent" >&2; return 1; }
    assert_contains "$out" "--binary" "the error must name the missing flag" || return 1

    rc=0
    out=$(bash "$CC_UPDATE" --via binary --binary "$TEST_TMPDIR/does-not-exist" --version 2.1.280 2>&1) || rc=$?
    echo "    measured rc=$rc for a nonexistent path"
    [[ "$rc" -ne 0 ]] || { echo "    must refuse a nonexistent --binary path" >&2; return 1; }
    assert_contains "$(cat "$HOME/.cc-mirror/mclaude/native/claude")" "2.1.113" "the installed binary must be untouched"
}
run_test "--via binary refuses without a usable source binary" test_binary_requires_source

# ══════════════════════════════════════════════════════════════════════════════
# TEST 16: --via binary VERIFIES the source before swapping
# ══════════════════════════════════════════════════════════════════════════════
# Handover 2026-09-23 step 4: "chmod +x then ./claude.new --version must print the
# intended version. Abort if not." A swap-then-check would leave a Deck dead.

test_binary_verifies_before_swap() {
    create_native_sandbox "2.1.113"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    make_stub_binary "$TEST_TMPDIR/claude.new" "2.1.99"   # WRONG version on purpose
    local out rc=0
    out=$(bash "$CC_UPDATE" --via binary --binary "$TEST_TMPDIR/claude.new" --version 2.1.280 2>&1) || rc=$?
    local installed; installed=$("$HOME/.cc-mirror/mclaude/native/claude")
    echo "    measured rc=$rc, installed binary still reports: $installed"
    [[ "$rc" -ne 0 ]] || { echo "    must refuse a source that reports the wrong version" >&2; return 1; }
    assert_contains "$out" "2.1.99" "the error must print what the source actually reported" || return 1
    assert_contains "$installed" "2.1.113" "the old binary must still be in place (no swap)"
}
run_test "--via binary verifies the source version before swapping" test_binary_verifies_before_swap

# ══════════════════════════════════════════════════════════════════════════════
# TEST 17: --via binary installs, rewires the launcher and re-pins variant.json
# ══════════════════════════════════════════════════════════════════════════════

test_binary_happy_path() {
    create_native_sandbox "2.1.113"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    make_stub_binary "$TEST_TMPDIR/claude.new" "2.1.280"
    bash "$CC_UPDATE" --via binary --binary "$TEST_TMPDIR/claude.new" --version 2.1.280 >/dev/null 2>&1 || true
    local native="$HOME/.cc-mirror/mclaude/native/claude"
    local reported; reported=$("$native" 2>/dev/null || echo "<dead>")
    local orig; orig=$(grep -o '"claudeOrig": *"[^"]*"' "$HOME/.cc-mirror/mclaude/variant.json" || echo "<absent>")
    local execline; execline=$(tail -1 "$HOME/.local/bin/mclaude")
    echo "    measured installed=[$reported] claudeOrig=[$orig] exec=[$(printf '%s' "$execline" | cut -c1-70)]"
    assert_contains "$reported" "2.1.280" "the installed binary must report the target" || return 1
    assert_contains "$orig" "native:2.1.280" "claudeOrig must be re-pinned to the installed version" || return 1
    assert_contains "$execline" "native/claude" "the launcher must exec the native binary" || return 1
    assert_not_contains "$execline" "exec node" "a native install must not be exec'd through node"
}
run_test "--via binary installs, rewires launcher, re-pins variant.json" test_binary_happy_path

# ══════════════════════════════════════════════════════════════════════════════
# TEST 18: the replaced binary is backed up (a Deck must be recoverable)
# ══════════════════════════════════════════════════════════════════════════════

test_binary_backs_up_old() {
    create_native_sandbox "2.1.113"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    make_stub_binary "$TEST_TMPDIR/claude.new" "2.1.280"
    bash "$CC_UPDATE" --via binary --binary "$TEST_TMPDIR/claude.new" --version 2.1.280 >/dev/null 2>&1 || true
    local backup; backup=$(ls -d "$HOME/.cc-mirror/mclaude/native"* 2>/dev/null | grep -v '/native$' | head -1 || true)
    echo "    measured backup dir: ${backup:-<none>}"
    [[ -n "$backup" ]] || { echo "    no native/ backup was taken" >&2; return 1; }
    assert_contains "$("$backup/claude" 2>/dev/null || echo '<dead>')" "2.1.113" "the backup must hold the PREVIOUS binary"
}
run_test "--via binary backs up the replaced binary" test_binary_backs_up_old

# ══════════════════════════════════════════════════════════════════════════════
# TEST 19: --via auto picks the binary road when a source binary is supplied
# ══════════════════════════════════════════════════════════════════════════════
# A node-less Deck must never be routed to `npx -y cc-mirror` — there is no npx.

test_auto_prefers_binary_when_supplied() {
    create_native_sandbox "2.1.113"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    make_stub_binary "$TEST_TMPDIR/claude.new" "2.1.280"
    local out
    out=$(bash "$CC_UPDATE" --binary "$TEST_TMPDIR/claude.new" --version 2.1.280 --dry-run 2>&1 || true)
    echo "    measured: $(printf '%s' "$out" | grep -iE 'via|installer' | head -2 | tr '\n' ' ' | cut -c1-110)"
    assert_contains "$out" "via binary" "auto must resolve to the binary road when --binary is given" || return 1
    assert_not_contains "$out" "npx" "a node-less machine must not be routed through npx"
}
run_test "--via auto prefers the binary road when --binary is supplied" test_auto_prefers_binary_when_supplied

# ══════════════════════════════════════════════════════════════════════════════
# TEST 20: a FOREIGN update-checker reference must not block the fleet's wiring
# ══════════════════════════════════════════════════════════════════════════════
# MEASURED on deck2, 2026-09-23: its launcher carried a cc-mirror-generated block calling
# ~/.cc-mirror/mclaude/scripts/update-checker.sh. The old guard tested for the bare string
# "update-checker.sh", matched that foreign line, and concluded "already wired" — so the
# FLEET checker was never installed. The foreign one cannot fire on that machine either
# (it reads the version through `node -e` from an npm/ tree a native layout does not have,
# and deck2 has no node on PATH), and it prints `npm update` as the remedy. Net effect:
# deck2 silently fell 142 releases behind while looking correctly wired.

test_foreign_update_checker_does_not_block_wiring() {
    create_cc_mirror_sandbox "2.1.111"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    mkdir -p "$HOME/cfg-agent-fleet/setup/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/cfg-agent-fleet/setup/scripts/update-checker.sh"
    # A foreign checker, wired above the exec line exactly as cc-mirror leaves it.
    local launcher="$HOME/.local/bin/mclaude" n
    n=$(grep -n '^exec ' "$launcher" | tail -1 | cut -d: -f1)
    { head -n $((n - 1)) "$launcher"
      printf '%s\n' 'if [[ -x "$HOME/.cc-mirror/mclaude/scripts/update-checker.sh" ]]; then'
      printf '%s\n' '  "$HOME/.cc-mirror/mclaude/scripts/update-checker.sh" || true'
      printf '%s\n' 'fi'
      tail -n +"$n" "$launcher"; } > "$launcher.tmp"
    mv "$launcher.tmp" "$launcher"; chmod +x "$launcher"

    setup_mock_npm "2.2.0"
    bash "$CC_UPDATE" --version 2.2.0 >/dev/null 2>&1 || true
    local fleet_lines; fleet_lines=$(grep -c 'CONFIG_REPO' "$launcher" || true)
    echo "    measured: fleet block lines=${fleet_lines:-0}, foreign lines=$(grep -c 'cc-mirror/mclaude/scripts/update-checker' "$launcher" || true)"
    [[ "${fleet_lines:-0}" -ge 1 ]] || { echo "    the fleet checker was NOT wired (foreign reference masked it)" >&2; return 1; }

    # And still idempotent: a second update must not add a second fleet block.
    setup_mock_npm "2.3.0"
    bash "$CC_UPDATE" --version 2.3.0 >/dev/null 2>&1 || true
    echo "    measured after second update: fleet block lines=$(grep -c 'CONFIG_REPO' "$launcher" || true)"
    assert_eq "$fleet_lines" "$(grep -c 'CONFIG_REPO' "$launcher" || true)" "wiring must stay idempotent"
}
run_test "a foreign update-checker reference does not block the fleet wiring" test_foreign_update_checker_does_not_block_wiring

# ══════════════════════════════════════════════════════════════════════════════
# TEST 21: an already-up-to-date install still gets the fleet checker wired
# ══════════════════════════════════════════════════════════════════════════════
# deck2 was AT the target version with no fleet checker. If "already up to date" exits
# before the wiring, the one machine that most needs the nag is the one that never gets it.

test_up_to_date_still_wires_checker() {
    create_cc_mirror_sandbox "2.2.0"
    unset CLAUDE_CONFIG_DIR 2>/dev/null || true
    mkdir -p "$HOME/cfg-agent-fleet/setup/scripts"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/cfg-agent-fleet/setup/scripts/update-checker.sh"
    local launcher="$HOME/.local/bin/mclaude"
    local before; before=$(grep -c 'CONFIG_REPO' "$launcher" || true)
    local out; out=$(bash "$CC_UPDATE" --version 2.2.0 2>&1 || true)
    local after; after=$(grep -c 'CONFIG_REPO' "$launcher" || true)
    echo "    measured: up-to-date path, fleet block lines ${before:-0} → ${after:-0}"
    assert_contains "$out" "Already up to date" "this must be the up-to-date path" || return 1
    [[ "${after:-0}" -ge 1 ]] || { echo "    an up-to-date install was left unwired" >&2; return 1; }
    assert_contains "$(tail -1 "$launcher")" "exec" "exec must remain the last line"
}
run_test "an already-up-to-date install still gets the checker wired" test_up_to_date_still_wires_checker

# ══════════════════════════════════════════════════════════════════════════════

suite_summary
