#!/usr/bin/env bash
# E2E test: update notification mechanism
# Verifies the full lifecycle: fresh install at v1.0 → remote bumps to v1.1 →
# git-sync-check.sh detects update → upgrade.sh pulls and deploys → re-check clean.
#
# Uses isolated temp git repos (bare "remote" + local "clone") — no real network.
#
# Usage:
#   test-e2e-update-notification.sh              # refuse outside VM
#   test-e2e-update-notification.sh --force       # run on personal machine
#
# Run via: vm-exec.sh afleet-e2e --script setup/tests/test-e2e-update-notification.sh

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

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc (expected: '$expected', got: '$actual')"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc ('$needle' not found in output)"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $desc ('$needle' unexpectedly found in output)"
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

# ── Setup: create isolated git environment ──────────────────────────────────

TMPDIR_BASE="$(mktemp -d "${TMPDIR:-/tmp}/e2e-update.XXXXXX")"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

REMOTE_BARE="$TMPDIR_BASE/remote.git"
LOCAL_CLONE="$TMPDIR_BASE/local"
HELPER_CLONE="$TMPDIR_BASE/helper"

# Use the real scripts from agent-fleet (or cfg-agent-fleet as fallback)
AF_DIR="$HOME/agent-fleet"
if [[ ! -d "$AF_DIR" ]]; then
    AF_DIR="$HOME/cfg-agent-fleet"
fi

SYNC_CHECK="$AF_DIR/setup/scripts/git-sync-check.sh"
UPGRADE_SH="$AF_DIR/setup/scripts/upgrade.sh"

echo "=== E2E Update Notification Test ==="
echo "  Scripts from: $AF_DIR"
echo "  Temp dir: $TMPDIR_BASE"

# --- Build the "remote" bare repo with v1.0 content ---
echo ""
echo "=== Phase 0: Build isolated git environment ==="

git init --bare -b main "$REMOTE_BARE" >/dev/null 2>&1

# Create a helper clone to push initial content
mkdir -p "$HELPER_CLONE"
(
    cd "$HELPER_CLONE"
    git init -b main >/dev/null 2>&1
    git config user.email "test@test.com"
    git config user.name "Test"

    # Minimal agent-fleet structure at v1.0
    echo "1.0" > .agent-fleet-version
    cat > setup.sh << 'SETUP_EOF'
#!/usr/bin/env bash
echo "setup.sh placeholder"
SETUP_EOF
    chmod +x setup.sh

    cat > sync.sh << 'SYNC_EOF'
#!/usr/bin/env bash
echo "sync.sh placeholder — deploy: $1"
SYNC_EOF
    chmod +x sync.sh

    mkdir -p setup/scripts
    # Copy the real git-sync-check.sh and upgrade.sh into the test repo
    cp "$SYNC_CHECK" setup/scripts/git-sync-check.sh
    cp "$UPGRADE_SH" setup/scripts/upgrade.sh

    mkdir -p global
    echo "# CLAUDE.md v1.0" > global/CLAUDE.md

    git add -A
    git commit -m "Initial release v1.0" >/dev/null 2>&1
    git remote add origin "$REMOTE_BARE"
    git push -u origin main >/dev/null 2>&1
)

# Clone the "local" copy (simulates user's machine)
git clone "$REMOTE_BARE" "$LOCAL_CLONE" --quiet 2>/dev/null
(
    cd "$LOCAL_CLONE"
    git config user.email "test@test.com"
    git config user.name "Test"
)

echo "  Remote bare repo: $REMOTE_BARE"
echo "  Local clone: $LOCAL_CLONE"
echo "  Helper clone: $HELPER_CLONE"

# ============================================================
# Phase 1: Fresh install at v1.0
# ============================================================
echo ""
echo "=== Phase 1: Fresh install at v1.0 ==="

VERSION_FILE="$LOCAL_CLONE/.agent-fleet-version"
assert_exists "version file exists in local clone" "$VERSION_FILE"

LOCAL_VER=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
assert "version file reads 1.0" "1.0" "$LOCAL_VER"

# git-sync-check should report up-to-date
OUT_PHASE1=""
RC_PHASE1=0
OUT_PHASE1=$(bash "$SYNC_CHECK" --pull "$LOCAL_CLONE" 2>&1) || RC_PHASE1=$?
assert "sync-check exits 0 (up to date)" "0" "$RC_PHASE1"
assert_contains "reports up to date" "Up to date" "$OUT_PHASE1"
assert_not_contains "no update notification when current" "UPDATE AVAILABLE" "$OUT_PHASE1"

echo "  PASS: Local is at v1.0, sync reports up-to-date"

# ============================================================
# Phase 2: Push v1.1 to remote, detect update via sync-check
# ============================================================
echo ""
echo "=== Phase 2: Remote bumps to v1.1, detect via git-sync-check ==="

# Push v1.1 from the helper clone
(
    cd "$HELPER_CLONE"
    echo "1.1" > .agent-fleet-version
    echo "# CLAUDE.md v1.1 — new feature" > global/CLAUDE.md
    git add -A
    git commit -m "Release v1.1" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
)

# Run git-sync-check WITHOUT --pull (report only)
OUT_REPORT=""
RC_REPORT=0
OUT_REPORT=$(bash "$SYNC_CHECK" "$LOCAL_CLONE" 2>&1) || RC_REPORT=$?
assert "sync-check exits 1 (behind, no --pull)" "1" "$RC_REPORT"
assert_contains "reports behind remote" "BEHIND remote by 1" "$OUT_REPORT"
assert_contains "shows incoming commit" "Release v1.1" "$OUT_REPORT"

echo "  PASS: sync-check detects 1 commit behind with v1.1 release"

# Run git-sync-check WITH --pull
OUT_PULL=""
RC_PULL=0
OUT_PULL=$(bash "$SYNC_CHECK" --pull "$LOCAL_CLONE" 2>&1) || RC_PULL=$?
assert "sync-check --pull exits 0" "0" "$RC_PULL"
assert_contains "reports pull success" "Pulled successfully" "$OUT_PULL"

# After pull, version file should now read 1.1
LOCAL_VER_POST_PULL=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
assert "version file reads 1.1 after pull" "1.1" "$LOCAL_VER_POST_PULL"

echo "  PASS: Pull brought version to 1.1"

# ============================================================
# Phase 3: Verify [UPDATE AVAILABLE] notification mechanism
# ============================================================
echo ""
echo "=== Phase 3: Verify UPDATE AVAILABLE notification ==="

# The [UPDATE AVAILABLE] message fires when the repo is ahead of remote
# (local unpushed commits) AND local .agent-fleet-version < remote version.
# This simulates: user on v1.0 with local customization, remote at v1.1.

# Reset local to a state where it's ahead with an older version:
# 1. Reset remote version file to 1.1 (already there)
# 2. Local: rewrite .agent-fleet-version to 1.0, add a local commit (making it ahead)
(
    cd "$LOCAL_CLONE"
    echo "1.0" > .agent-fleet-version
    git add .agent-fleet-version
    git commit -m "Local customization (still v1.0)" >/dev/null 2>&1
)

# Push the v1.1 state to remote so remote has "1.1" in .agent-fleet-version
# but local has "1.0" with an extra commit on top
(
    cd "$HELPER_CLONE"
    # Ensure remote is at v1.1 (already is from Phase 2)
    true
)

# Now local is 1 ahead of remote (has the customization commit).
# Remote .agent-fleet-version shows "1.1", local shows "1.0".
# This is the condition that triggers [UPDATE AVAILABLE].
OUT_UPDATE=""
RC_UPDATE=0
OUT_UPDATE=$(bash "$SYNC_CHECK" "$LOCAL_CLONE" 2>&1) || RC_UPDATE=$?
assert "sync-check exits 0 (ahead)" "0" "$RC_UPDATE"
assert_contains "reports ahead of remote" "Ahead of remote" "$OUT_UPDATE"
assert_contains "[UPDATE AVAILABLE] notification shown" "UPDATE AVAILABLE" "$OUT_UPDATE"
assert_contains "shows version transition" "1.0" "$OUT_UPDATE"
assert_contains "shows target version" "1.1" "$OUT_UPDATE"

echo "  PASS: [UPDATE AVAILABLE] fires when local version < remote version"

# ============================================================
# Phase 4: Run upgrade.sh → verify version update
# ============================================================
echo ""
echo "=== Phase 4: Run upgrade.sh ==="

# Reset local clone to v1.0 state (behind remote) for a clean upgrade test.
# Undo the local customization commit so we're behind again.
(
    cd "$LOCAL_CLONE"
    git reset --hard HEAD~2 >/dev/null 2>&1
)

LOCAL_VER_PRE=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
assert "pre-upgrade version is 1.0" "1.0" "$LOCAL_VER_PRE"

# Run upgrade.sh with --skip-deploy (sync.sh is a placeholder) and --repo
OUT_UPGRADE=""
RC_UPGRADE=0
OUT_UPGRADE=$(bash "$UPGRADE_SH" --skip-deploy --repo "$LOCAL_CLONE" 2>&1) || RC_UPGRADE=$?
assert "upgrade.sh exits 0" "0" "$RC_UPGRADE"
assert_contains "upgrade reports success" "Upgraded" "$OUT_UPGRADE"
assert_contains "rollback tag created" "pre-upgrade" "$OUT_UPGRADE"

LOCAL_VER_POST=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
assert "post-upgrade version is 1.1" "1.1" "$LOCAL_VER_POST"

echo "  PASS: upgrade.sh pulled v1.1 and created rollback tag"

# ============================================================
# Phase 5: Post-upgrade — no update notification
# ============================================================
echo ""
echo "=== Phase 5: Post-upgrade re-check ==="

OUT_RECHECK=""
RC_RECHECK=0
OUT_RECHECK=$(bash "$SYNC_CHECK" --pull "$LOCAL_CLONE" 2>&1) || RC_RECHECK=$?
assert "post-upgrade sync-check exits 0" "0" "$RC_RECHECK"
assert_contains "reports up to date" "Up to date" "$OUT_RECHECK"
assert_not_contains "no update notification after upgrade" "UPDATE AVAILABLE" "$OUT_RECHECK"

echo "  PASS: No update notification after upgrade — already current"

# ============================================================
# Phase 6: Rollback support
# ============================================================
echo ""
echo "=== Phase 6: Rollback verification ==="

# Verify rollback tag exists
OUT_TAGS=""
OUT_TAGS=$(bash "$UPGRADE_SH" --list-tags --repo "$LOCAL_CLONE" 2>&1)
assert_contains "rollback tag listed" "pre-upgrade-" "$OUT_TAGS"

# Perform rollback
OUT_ROLLBACK=""
RC_ROLLBACK=0
OUT_ROLLBACK=$(bash "$UPGRADE_SH" --rollback --skip-deploy --repo "$LOCAL_CLONE" 2>&1) || RC_ROLLBACK=$?
assert "rollback exits 0" "0" "$RC_ROLLBACK"
assert_contains "rollback reports success" "Rolled back" "$OUT_ROLLBACK"

LOCAL_VER_ROLLBACK=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
assert "version is 1.0 after rollback" "1.0" "$LOCAL_VER_ROLLBACK"

echo "  PASS: Rollback restored v1.0"

# ============================================================
# Results
# ============================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    echo -e "Failures:$ERRORS"
    exit 1
fi
echo "All E2E update notification tests passed."
