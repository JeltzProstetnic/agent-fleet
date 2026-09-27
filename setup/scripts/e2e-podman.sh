#!/usr/bin/env bash
# e2e-podman.sh — Run E2E deployment tests in a Podman container.
# Works on any machine with Podman (Fedora, SteamOS, NUC, etc.).
# No VM needed — uses rootless Podman containers for isolation.
#
# Usage:
#   e2e-podman.sh                    # run deployment E2E
#   e2e-podman.sh --all              # run all E2E tests
#   e2e-podman.sh --test <name>      # run specific test (deployment, onboarding, upgrade, daily)
#   e2e-podman.sh --keep             # don't remove container after run (for debugging)
#   e2e-podman.sh --image <img>      # use custom image (default: fedora:42)
#
# Requirements: podman, network access (to clone agent-fleet from GitHub)

set -euo pipefail

# --- Config ---
IMAGE="${E2E_IMAGE:-docker.io/library/fedora:42}"
CONTAINER_NAME="afleet-e2e-$$"
KEEP=false
TESTS=("deployment")
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)     TESTS=("deployment" "onboarding" "upgrade-path" "daily-workflow"); shift ;;
        --test)    TESTS=("$2"); shift 2 ;;
        --keep)    KEEP=true; shift ;;
        --image)   IMAGE="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^$/s/^# //p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Preflight ---
if ! command -v podman &>/dev/null; then
    echo "ERROR: podman not found. Install with: sudo dnf install podman" >&2
    exit 1
fi

# Verify test scripts exist
for test_name in "${TESTS[@]}"; do
    test_script="$REPO_ROOT/setup/tests/test-e2e-${test_name}.sh"
    if [[ ! -f "$test_script" ]]; then
        echo "ERROR: Test script not found: $test_script" >&2
        exit 1
    fi
done

# --- Pull image if needed ---
echo "=== E2E Podman Runner ==="
echo "Image:     $IMAGE"
echo "Tests:     ${TESTS[*]}"
echo "Container: $CONTAINER_NAME"
echo ""

if ! podman image exists "$IMAGE" 2>/dev/null; then
    echo "Pulling image..."
    podman pull "$IMAGE"
fi

# --- Cleanup handler ---
cleanup() {
    if [[ "$KEEP" == "false" ]]; then
        podman rm -f "$CONTAINER_NAME" &>/dev/null || true
    else
        echo ""
        echo "Container kept: $CONTAINER_NAME"
        echo "  Debug:   podman exec -it $CONTAINER_NAME bash"
        echo "  Remove:  podman rm -f $CONTAINER_NAME"
    fi
}
trap cleanup EXIT

# --- Create and start container ---
echo "Creating container..."
podman create --name "$CONTAINER_NAME" \
    --hostname "e2e-test" \
    "$IMAGE" \
    sleep infinity >/dev/null

podman start "$CONTAINER_NAME" >/dev/null

# --- Install prerequisites inside container ---
echo "Installing prerequisites (git, Node.js, python3)..."
podman exec "$CONTAINER_NAME" bash -c '
    dnf install -y -q git curl findutils procps-ng hostname nodejs python3 2>/dev/null
    echo "Node $(node --version), npm $(npm --version)"
' 2>&1 | tail -1

# --- Clone agent-fleet ---
echo "Cloning agent-fleet..."
podman exec "$CONTAINER_NAME" bash -c '
    export HOME=/root
    cd "$HOME"
    git clone --depth 1 https://github.com/JeltzProstetnic/agent-fleet.git 2>&1 | tail -1
'

# --- Run setup ---
echo "Running agent-fleet setup..."
podman exec "$CONTAINER_NAME" bash -c '
    export HOME=/root
    cd "$HOME/agent-fleet"
    echo "y" | bash setup.sh --skip-preflight 2>&1 | tail -10
'

# --- Copy and run E2E tests ---
OVERALL_PASS=0
OVERALL_FAIL=0

for test_name in "${TESTS[@]}"; do
    test_script="$REPO_ROOT/setup/tests/test-e2e-${test_name}.sh"
    echo ""
    echo "════════════════════════════════════════"
    echo "Running E2E: ${test_name}"
    echo "════════════════════════════════════════"

    # Copy test script into container
    podman cp "$test_script" "$CONTAINER_NAME:/root/test-e2e-${test_name}.sh"

    # Run it
    if podman exec "$CONTAINER_NAME" bash -c "
        export HOME=/root
        chmod +x /root/test-e2e-${test_name}.sh
        /root/test-e2e-${test_name}.sh
    " 2>&1; then
        OVERALL_PASS=$((OVERALL_PASS + 1))
    else
        OVERALL_FAIL=$((OVERALL_FAIL + 1))
    fi
done

# --- Summary ---
echo ""
echo "════════════════════════════════════════"
echo "E2E Summary: $OVERALL_PASS passed, $OVERALL_FAIL failed (${#TESTS[@]} tests)"
if [[ $OVERALL_FAIL -gt 0 ]]; then
    echo "FAIL — use --keep to debug"
    exit 1
fi
echo "All E2E tests passed."

# Record the run so anti-lockout-check.sh can tell a Tier 2 edit has been verified
# (CFG-586). Written only on success — a failed run must not satisfy the gate.
_e2e_marker="${ANTILOCKOUT_E2E_MARKER:-$HOME/.claude/.last-e2e-run}"
mkdir -p "$(dirname "$_e2e_marker")" 2>/dev/null || true
date -Iseconds > "$_e2e_marker" 2>/dev/null \
    && echo "Recorded E2E run: $_e2e_marker"
