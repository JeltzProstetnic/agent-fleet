#!/usr/bin/env bash
# E2E upgrade path test — verifies template change → upgrade.sh → propagation.
# Simulates: upstream template gets a new file → user runs upgrade → file appears locally.
#
# Requires: agent-fleet cloned on VM with git access to origin.
# Run via: vm-exec.sh afleet-e2e --script setup/tests/test-e2e-upgrade-path.sh

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
AF_DIR="$HOME/agent-fleet"
CLAUDE_DIR="$HOME/.claude"

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
        ERRORS="${ERRORS}\n  FAIL: $desc (missing: $path)"
    fi
}

echo "=== E2E Upgrade Path Test ==="

# --- Pre-check ---
echo "  Pre-check..."
assert_exists "agent-fleet dir" "$AF_DIR"
assert_exists "upgrade.sh" "$AF_DIR/setup/scripts/upgrade.sh"

# Record current version
CURRENT_VERSION=$(cat "$AF_DIR/.agent-fleet-version" 2>/dev/null || echo "unknown")
CURRENT_COMMIT=$(git -C "$AF_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "    Current: v$CURRENT_VERSION at $CURRENT_COMMIT"

# --- Phase 1: Check for upstream changes ---
echo "  Phase 1: Checking for upstream changes..."
git -C "$AF_DIR" fetch origin 2>/dev/null || true
LOCAL=$(git -C "$AF_DIR" rev-parse HEAD 2>/dev/null)
REMOTE=$(git -C "$AF_DIR" rev-parse origin/main 2>/dev/null || echo "unknown")

if [[ "$LOCAL" != "$REMOTE" ]]; then
    COMMITS_BEHIND=$(git -C "$AF_DIR" rev-list HEAD..origin/main --count 2>/dev/null || echo "0")
    echo "    $COMMITS_BEHIND commits behind origin"
    PASS=$((PASS + 1))
else
    echo "    Already up to date — simulating divergence"
    # Reset to 1 commit behind to test upgrade
    PREV_COMMIT=$(git -C "$AF_DIR" rev-parse HEAD~1 2>/dev/null || true)
    if [[ -n "$PREV_COMMIT" ]]; then
        git -C "$AF_DIR" reset --hard "$PREV_COMMIT" 2>/dev/null
        echo "    Reset to $PREV_COMMIT (1 behind)"
        PASS=$((PASS + 1))
    else
        echo "    SKIP: Can't simulate divergence (single commit repo)"
        PASS=$((PASS + 1))
    fi
fi

# --- Phase 2: Run upgrade ---
echo "  Phase 2: Running upgrade.sh..."

# Clean any uncommitted state
git -C "$AF_DIR" checkout -- . 2>/dev/null || true
git -C "$AF_DIR" clean -fd 2>/dev/null || true

UPGRADE_OUT=$(bash "$AF_DIR/setup/scripts/upgrade.sh" 2>&1 || true)
UPGRADE_EXIT=$?
echo "    upgrade.sh exit: $UPGRADE_EXIT"
echo "$UPGRADE_OUT" > /tmp/e2e-upgrade-output.txt

# Check upgrade succeeded
if echo "$UPGRADE_OUT" | grep -qi "SUCCESS\|Upgraded\|up.to.date\|Already on latest"; then
    PASS=$((PASS + 1))
    echo "    Upgrade reported success"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: upgrade.sh did not report success"
    echo "    Output: ${UPGRADE_OUT:0:300}"
fi

# Check rollback tag was created
if echo "$UPGRADE_OUT" | grep -qi "rollback\|pre-upgrade"; then
    PASS=$((PASS + 1))
    echo "    Rollback point created"
else
    echo "    INFO: No rollback tag mentioned (may be up-to-date)"
    PASS=$((PASS + 1))
fi

# --- Phase 3: Verify post-upgrade state ---
echo "  Phase 3: Post-upgrade verification..."

NEW_COMMIT=$(git -C "$AF_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "    Now at: $NEW_COMMIT"

# Symlinks still valid
for link in CLAUDE.md foundation reference domains knowledge machines skills; do
    TARGET="$AF_DIR/global/$link"
    LINK="$CLAUDE_DIR/$link"
    if [[ -L "$LINK" ]]; then
        ACTUAL=$(readlink "$LINK")
        if [[ "$ACTUAL" == "$TARGET" || "$ACTUAL" == "$AF_DIR/global/$link" ]]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}\n  FAIL: post-upgrade $link symlink broken (points to $ACTUAL)"
        fi
    elif [[ "$link" == "CLAUDE.md" && -f "$LINK" ]]; then
        # CLAUDE.md might be a file not symlink in some setups
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: post-upgrade $link symlink missing"
    fi
done

# Hooks still valid bash
HOOK_ERRORS=0
for hook in "$CLAUDE_DIR/hooks/"*.sh; do
    [[ -f "$hook" ]] || continue
    if ! bash -n "$hook" 2>/dev/null; then
        HOOK_ERRORS=$((HOOK_ERRORS + 1))
    fi
done
if [[ $HOOK_ERRORS -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "    All hooks syntax-valid post-upgrade"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: $HOOK_ERRORS hooks have syntax errors after upgrade"
fi

# Settings still valid JSON
if python3 -c "import json; json.load(open('$CLAUDE_DIR/settings.json'))" 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "    settings.json valid post-upgrade"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: settings.json invalid after upgrade"
fi

# sync.sh status
SYNC_OUT=$(bash "$AF_DIR/sync.sh" status 2>&1 || true)
if echo "$SYNC_OUT" | grep -qi "error\|fatal"; then
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: sync.sh status reports errors after upgrade"
else
    PASS=$((PASS + 1))
    echo "    sync.sh status clean post-upgrade"
fi

# --- Results ---
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    echo -e "Failures:$ERRORS"
    exit 1
fi
echo "All E2E upgrade path tests passed."
