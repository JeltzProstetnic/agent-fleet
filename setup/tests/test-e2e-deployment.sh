#!/usr/bin/env bash
# E2E deployment and upgrade tests — runs ON the VM via vm-exec.sh or directly.
# Tests the full lifecycle: fresh deploy → verify → upgrade → verify again.
# No CC API key needed — tests infrastructure only.
#
# Usage:
#   test-e2e-deployment.sh                    # run all phases
#   test-e2e-deployment.sh --phase deploy     # fresh deployment only
#   test-e2e-deployment.sh --phase verify     # verify current state
#   test-e2e-deployment.sh --phase upgrade    # simulate upgrade + verify
#
# Expects: agent-fleet cloned at ~/agent-fleet, setup.sh already run.

set -euo pipefail

# Safety guard: E2E tests modify real files. Refuse to run outside a VM.
if [[ -f "$HOME/cfg-agent-fleet/.git/HEAD" && "${1:-}" != "--force" ]]; then
    echo "ERROR: E2E test detected cfg-agent-fleet (personal config repo)." >&2
    echo "Run only on a VM via: vm-exec.sh afleet-e2e --script $0" >&2
    exit 1
fi

PASS=0
FAIL=0
ERRORS=""
PHASE="${2:-all}"

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (expected: '$expected', got: '$actual')"
    fi
}

assert_exists() {
    local desc="$1" path="$2"
    if [[ -e "$path" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (path missing: $path)"
    fi
}

assert_symlink() {
    local desc="$1" path="$2" target="$3"
    if [[ -L "$path" ]]; then
        local actual
        actual=$(readlink "$path")
        if [[ "$actual" == "$target" ]]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}\n  FAIL: $desc (symlink points to '$actual', expected '$target')"
        fi
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (not a symlink: $path)"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -q "$needle" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc ('$needle' not found in $file)"
    fi
}

AF_DIR="$HOME/agent-fleet"
CLAUDE_DIR="$HOME/.claude"

# Resolve settings.json path — cc-mirror deploys to ~/.cc-mirror/mclaude/config/
if [[ -f "$HOME/.cc-mirror/mclaude/config/settings.json" ]]; then
    SETTINGS_PATH="$HOME/.cc-mirror/mclaude/config/settings.json"
else
    SETTINGS_PATH="$CLAUDE_DIR/settings.json"
fi

SKIP=0

# ============================================================
# Phase 1: Verify fresh deployment
# ============================================================
if [[ "$PHASE" == "all" || "$PHASE" == "deploy" || "$PHASE" == "verify" ]]; then
    echo "=== Phase: Deployment Verification ==="

    # --- Directory structure ---
    echo "  Checking directory structure..."
    assert_exists "agent-fleet exists" "$AF_DIR"
    assert_exists ".claude dir exists" "$CLAUDE_DIR"
    assert_exists "setup.sh exists" "$AF_DIR/setup.sh"
    assert_exists "sync.sh exists" "$AF_DIR/sync.sh"
    assert_exists "global/ exists" "$AF_DIR/global"
    assert_exists "setup/ exists" "$AF_DIR/setup"

    # --- Symlinks ---
    echo "  Checking symlinks..."
    assert_symlink "CLAUDE.md symlink" "$CLAUDE_DIR/CLAUDE.md" "$AF_DIR/global/CLAUDE.md"
    assert_symlink "foundation symlink" "$CLAUDE_DIR/foundation" "$AF_DIR/global/foundation"
    assert_symlink "reference symlink" "$CLAUDE_DIR/reference" "$AF_DIR/global/reference"
    assert_symlink "domains symlink" "$CLAUDE_DIR/domains" "$AF_DIR/global/domains"
    assert_symlink "knowledge symlink" "$CLAUDE_DIR/knowledge" "$AF_DIR/global/knowledge"
    assert_symlink "machines symlink" "$CLAUDE_DIR/machines" "$AF_DIR/global/machines"
    assert_symlink "skills symlink" "$CLAUDE_DIR/skills" "$AF_DIR/global/skills"

    # --- Key files exist ---
    echo "  Checking key files..."
    assert_exists ".setup-pending marker" "$AF_DIR/.setup-pending"
    assert_exists ".setup-verified" "$CLAUDE_DIR/.setup-verified"
    assert_exists "settings.json" "$SETTINGS_PATH"
    assert_exists "statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"

    # --- Settings.json is valid JSON ---
    echo "  Checking settings.json (at $SETTINGS_PATH)..."
    if python3 -c "import json; json.load(open('$SETTINGS_PATH'))" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: settings.json is not valid JSON"
    fi

    # --- Hooks deployed ---
    echo "  Checking hooks..."
    assert_exists "hooks dir" "$CLAUDE_DIR/hooks"
    assert_exists "safe-run.sh" "$CLAUDE_DIR/hooks/safe-run.sh"
    assert_exists "config-check.sh" "$CLAUDE_DIR/hooks/config-check.sh"
    assert_exists "config-auto-sync.sh" "$CLAUDE_DIR/hooks/config-auto-sync.sh"

    # Hook scripts are valid bash
    HOOK_ERRORS=0
    for hook in "$CLAUDE_DIR/hooks/"*.sh; do
        [[ -f "$hook" ]] || continue
        if ! bash -n "$hook" 2>/dev/null; then
            HOOK_ERRORS=$((HOOK_ERRORS + 1))
            ERRORS="${ERRORS}\n  FAIL: Hook syntax error: $(basename "$hook")"
        fi
    done
    if [[ $HOOK_ERRORS -eq 0 ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + $HOOK_ERRORS))
    fi
    echo "    $(ls "$CLAUDE_DIR/hooks/"*.sh 2>/dev/null | wc -l) hooks, $HOOK_ERRORS syntax errors"

    # --- sync.sh status ---
    echo "  Checking sync.sh status..."
    SYNC_OUT=$(bash "$AF_DIR/sync.sh" status 2>&1 || true)
    if echo "$SYNC_OUT" | grep -qi "error\|fatal\|not found"; then
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: sync.sh status reports errors"
    else
        PASS=$((PASS + 1))
    fi

    # --- CLAUDE.md loads without triggering errors ---
    echo "  Checking CLAUDE.md content..."
    assert_contains "CLAUDE.md has Knowledge Loading" "Knowledge Loading" "$CLAUDE_DIR/CLAUDE.md"
    # Template CLAUDE.md has "Knowledge Loading", personal has "Key Files" — either is valid
    if grep -qE "Knowledge Loading|Key Files|Claude Config" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: CLAUDE.md missing expected sections"
    fi

    # --- Foundation files ---
    echo "  Checking foundation files..."
    assert_exists "session-protocol.md" "$CLAUDE_DIR/foundation/session-protocol.md"
    assert_exists "personas.md" "$CLAUDE_DIR/foundation/personas.md"

    # --- Version file ---
    echo "  Checking version..."
    assert_exists ".agent-fleet-version" "$AF_DIR/.agent-fleet-version"
fi

# ============================================================
# Phase 2: Simulate upgrade
# ============================================================
if [[ "$PHASE" == "all" || "$PHASE" == "upgrade" ]]; then
    echo ""
    echo "=== Phase: Upgrade Simulation ==="

    # Check if upgrade.sh exists
    if [[ ! -f "$AF_DIR/setup/scripts/upgrade.sh" ]]; then
        echo "  SKIP: upgrade.sh not found (may not be in template yet)"
    else
        # Clean any uncommitted state from prior test runs
        git -C "$AF_DIR" checkout -- . 2>/dev/null || true
        git -C "$AF_DIR" clean -fd 2>/dev/null || true

        echo "  Running upgrade.sh..."
        UPGRADE_OUT=$(bash "$AF_DIR/setup/scripts/upgrade.sh" 2>&1 || true)
        echo "  ${UPGRADE_OUT:0:500}"

        # After upgrade check, verify nothing broke
        echo "  Re-verifying deployment..."

        # Symlinks still valid
        assert_symlink "post-upgrade CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md" "$AF_DIR/global/CLAUDE.md"
        assert_symlink "post-upgrade foundation" "$CLAUDE_DIR/foundation" "$AF_DIR/global/foundation"

        # Settings still valid JSON
        if python3 -c "import json; json.load(open('$SETTINGS_PATH'))" 2>/dev/null; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}\n  FAIL: post-upgrade settings.json is not valid JSON"
        fi

        # Hooks still syntax-valid
        POST_HOOK_ERRORS=0
        for hook in "$CLAUDE_DIR/hooks/"*.sh; do
            [[ -f "$hook" ]] || continue
            if ! bash -n "$hook" 2>/dev/null; then
                POST_HOOK_ERRORS=$((POST_HOOK_ERRORS + 1))
            fi
        done
        if [[ $POST_HOOK_ERRORS -eq 0 ]]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + $POST_HOOK_ERRORS))
            ERRORS="${ERRORS}\n  FAIL: $POST_HOOK_ERRORS hooks have syntax errors after upgrade"
        fi
    fi
fi

# ============================================================
# Phase 3: Verify CC-ready state (no API key needed)
# ============================================================
if [[ "$PHASE" == "all" || "$PHASE" == "verify" ]]; then
    echo ""
    echo "=== Phase: CC-Ready State ==="

    # CC installed and runnable (skip if not installed — infra-only is valid)
    echo "  Checking CC installation..."
    if command -v claude &>/dev/null; then
        CC_VER=$(claude --version 2>/dev/null || echo "unknown")
        echo "    CC version: $CC_VER"
        PASS=$((PASS + 1))
    else
        echo "    SKIP: claude not installed (infra-only deployment)"
        SKIP=$((SKIP + 1))
    fi

    # Node.js available
    if command -v node &>/dev/null; then
        echo "    Node: $(node --version)"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: node not found"
    fi
fi

# ============================================================
# Results
# ============================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ $FAIL -gt 0 ]]; then
    echo -e "Failures:$ERRORS"
    exit 1
fi
echo "All E2E deployment tests passed."
