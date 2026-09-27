#!/usr/bin/env bash
# E2E test for cc-update.sh — runs a REAL npm install on a VM.
# Installs CC 2.1.111, then upgrades to latest via cc-update.sh.
#
# Run via: vm-exec.sh afleet-e2e --script setup/tests/test-e2e-cc-update.sh

set -euo pipefail

if [[ -f "$HOME/cfg-agent-fleet/.git/HEAD" && "${1:-}" != "--force" ]]; then
    echo "ERROR: E2E test detected cfg-agent-fleet (personal config repo)." >&2
    echo "Run only on a VM via: vm-exec.sh afleet-e2e --script $0" >&2
    exit 1
fi

PASS=0
FAIL=0
ERRORS=""
MIRROR_DIR="$HOME/.cc-mirror-e2e"

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS $desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (expected: '$expected', got: '$actual')"
        echo "  FAIL $desc (expected: '$expected', got: '$actual')"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
        echo "  PASS $desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (missing: '$needle')"
        echo "  FAIL $desc (missing: '$needle' in output)"
    fi
}

assert_exists() {
    local desc="$1" path="$2"
    if [[ -e "$path" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS $desc"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (missing: $path)"
        echo "  FAIL $desc (missing: $path)"
    fi
}

cleanup() {
    echo "  Cleaning up $MIRROR_DIR..."
    rm -rf "$MIRROR_DIR" "$HOME/.local/bin/mclaude-e2e" "$HOME/.local/bin/mclaude-e2e-backup-*"
}

echo "=== E2E CC Update Test ==="

# --- Pre-check ---
echo "  Pre-check..."
command -v node >/dev/null || { echo "SKIP: node not installed"; exit 0; }
command -v npm >/dev/null || { echo "SKIP: npm not installed"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 0; }

NODE_VER=$(node --version)
echo "    Node: $NODE_VER"
echo "    npm: $(npm --version)"

# Clean any prior e2e state
cleanup 2>/dev/null || true

# --- Phase 1: Install old CC version (2.1.111) ---
echo ""
echo "  Phase 1: Installing CC 2.1.111 (old cli.js architecture)..."
mkdir -p "$MIRROR_DIR/npm" "$MIRROR_DIR/tweakcc" "$HOME/.local/bin"

(cd "$MIRROR_DIR/npm" && npm install "@anthropic-ai/claude-code@2.1.111" --no-save 2>&1 | tail -3)

CC_PKG="$MIRROR_DIR/npm/node_modules/@anthropic-ai/claude-code"
OLD_VER=$(python3 -c "import json; print(json.load(open('$CC_PKG/package.json'))['version'])")
assert "old version installed" "2.1.111" "$OLD_VER"
assert_exists "cli.js exists" "$CC_PKG/cli.js"

# Create variant.json
cat > "$MIRROR_DIR/variant.json" << VAREOF
{
  "name": "mclaude-e2e",
  "provider": "mirror",
  "binaryPath": "$CC_PKG/cli.js",
  "npmDir": "$MIRROR_DIR/npm",
  "npmVersion": "$OLD_VER",
  "updatedAt": "2026-01-01T00:00:00.000Z"
}
VAREOF

# Create launcher
cat > "$HOME/.local/bin/mclaude-e2e" << LAUNCHEOF
#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_CONFIG_DIR="$MIRROR_DIR/config"
exec node "$CC_PKG/cli.js" "\$@"
LAUNCHEOF
chmod +x "$HOME/.local/bin/mclaude-e2e"

# --- Phase 2: Create a modified cc-update.sh that uses our e2e paths ---
echo ""
echo "  Phase 2: Preparing update script..."

UPDATE_SCRIPT="$MIRROR_DIR/cc-update-e2e.sh"
if [[ -f "$HOME/agent-fleet/setup/scripts/cc-update.sh" ]]; then
    cp "$HOME/agent-fleet/setup/scripts/cc-update.sh" "$UPDATE_SCRIPT"
elif [[ -f /tmp/cc-update.sh ]]; then
    cp /tmp/cc-update.sh "$UPDATE_SCRIPT"
else
    echo "  SKIP: cc-update.sh not found on VM"
    cleanup
    exit 0
fi

# Patch the script to use e2e paths
sed -i "s|MIRROR_DIR=\"\$HOME/.cc-mirror/mclaude\"|MIRROR_DIR=\"$MIRROR_DIR\"|" "$UPDATE_SCRIPT"
sed -i "s|LAUNCHER=\"\$HOME/.local/bin/mclaude\"|LAUNCHER=\"$HOME/.local/bin/mclaude-e2e\"|" "$UPDATE_SCRIPT"
chmod +x "$UPDATE_SCRIPT"

# --- Phase 3: Run the update ---
echo ""
echo "  Phase 3: Running cc-update.sh to latest..."
unset CLAUDE_CONFIG_DIR 2>/dev/null || true

LATEST=$(npm view @anthropic-ai/claude-code version 2>/dev/null)
echo "    Target: $LATEST"

UPDATE_OUTPUT=$(bash "$UPDATE_SCRIPT" --version "$LATEST" 2>&1) || {
    echo "  FAIL: cc-update.sh exited non-zero"
    echo "$UPDATE_OUTPUT"
    FAIL=$((FAIL + 1))
}

# --- Phase 4: Verify ---
echo ""
echo "  Phase 4: Verification..."

NEW_VER=$(python3 -c "import json; print(json.load(open('$CC_PKG/package.json'))['version'])")
assert "package.json updated" "$LATEST" "$NEW_VER"

# Native binary should exist
if [[ -f "$CC_PKG/bin/claude.exe" ]]; then
    assert_exists "bin/claude.exe exists" "$CC_PKG/bin/claude.exe"
    BINARY="$CC_PKG/bin/claude.exe"
elif [[ -f "$CC_PKG/bin/claude" ]]; then
    assert_exists "bin/claude exists" "$CC_PKG/bin/claude"
    BINARY="$CC_PKG/bin/claude"
else
    echo "  FAIL: no native binary found"
    FAIL=$((FAIL + 1))
    BINARY=""
fi

# Launcher updated
LAST_LINE=$(tail -1 "$HOME/.local/bin/mclaude-e2e")
assert_contains "launcher points to binary" "$LAST_LINE" "bin/claude"
assert_contains "launcher uses exec" "$LAST_LINE" "exec"

# variant.json updated
assert_contains "variant.json has new version" "$(cat "$MIRROR_DIR/variant.json")" "$LATEST"

# Binary runs
if [[ -n "$BINARY" && -x "$BINARY" ]]; then
    BIN_VER=$("$BINARY" --version 2>/dev/null || true)
    assert_contains "binary reports version" "$BIN_VER" "$LATEST"
fi

# Backup exists
assert_exists "npm backup exists" "${MIRROR_DIR}/npm-backup-2.1.111"

# Rollback instructions shown
assert_contains "output has rollback" "$UPDATE_OUTPUT" "Rollback"

# --- Cleanup ---
echo ""
cleanup

# --- Summary ---
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
    printf "$ERRORS\n"
    exit 1
fi
echo "  ALL PASSED"
