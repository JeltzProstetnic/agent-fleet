#!/usr/bin/env bash
# cc-update-fleet.sh — update Claude Code on the SSH-reachable fleet machines from here.
# Run from a plain shell after /exit, like cc-update.sh itself.
#
# It owns transport and refusals only. The update itself is always cc-update.sh, shipped
# fresh to the target and run there, so there is exactly one implementation of the phases,
# the rollback and the post-condition — and a stale repo checkout on a remote cannot run
# an older, unhardened wrapper.
#
# Roads, chosen per host from a measured probe (never from this file's assumptions):
#   native layout → --via binary: the ELF from the npm tarball, verified HERE, scp'd, and
#                   swapped there. Needs no node on the target. MEASURED 2026-09-23:
#                   `bash -lc 'command -v node'` is EMPTY on deck and deck2, so this is
#                   not a preference, it is the only road those two machines have.
#   npm layout    → the npm road (vps).
#
# Refusals, all of them before anything is shipped:
#   - a target that is not a concrete x.y.z
#   - a source binary that does not report the target version
#   - a host whose arch does not match the binary
#   - a host with a live Claude Code session (MG uses the Decks in bed) — --force overrides
#
# Tests: setup/tests/test-cc-update-fleet.sh (transport stubbed via CC_FLEET_SSH/SCP).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH="${CC_FLEET_SSH:-ssh}"
SCP="${CC_FLEET_SCP:-scp}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=25)
# Host list: env override, else the head-owned conf (personal content; the public
# template ships commented examples only — precedent: setup/config/network-signals.conf).
# No built-in default: a hardcoded list of one fleet's SSH aliases is personal data and
# would not survive the propagation leak gate.
HOSTS_CONF="${CC_FLEET_HOSTS_FILE:-$SCRIPT_DIR/../config/cc-fleet-hosts.conf}"
DEFAULT_HOSTS="${CC_FLEET_HOSTS:-}"
if [[ -z "$DEFAULT_HOSTS" && -f "$HOSTS_CONF" ]]; then
    DEFAULT_HOSTS=$(sed 's/#.*//' "$HOSTS_CONF" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')
fi
STAGING=".cc-update-staging"

TARGET_VERSION="latest"
BINARY_SRC=""
DRY_RUN=false
FORCE=false
HOSTS=()

usage() {
    printf "Usage: %s [--host <h>]... [--all] [--version <x.y.z|latest>]\n" "$(basename "$0")"
    printf "       %*s [--binary <path>] [--dry-run] [--force]\n" "${#0}" ""
    printf "       --all        every host in CC_FLEET_HOSTS or %s\n" "$HOSTS_CONF"
    printf "                    (currently: %s)\n" "${DEFAULT_HOSTS:-<none configured>}"
    printf "       --binary     use this ELF instead of fetching the npm tarball\n"
    printf "       --force      update a host even with a live Claude Code session on it\n"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)    HOSTS+=("$2"); shift 2 ;;
        --all)     if [[ -z "$DEFAULT_HOSTS" ]]; then
                       printf "ERROR: --all needs a host list. Set CC_FLEET_HOSTS, or create %s\n" "$HOSTS_CONF"
                       exit 1
                   fi
                   read -r -a _d <<< "$DEFAULT_HOSTS"; HOSTS+=("${_d[@]}"); shift ;;
        --version) TARGET_VERSION="$2"; shift 2 ;;
        --binary)  BINARY_SRC="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force)   FORCE=true; shift ;;
        -h|--help) usage ;;
        *) printf "Unknown option: %s\n" "$1"; usage ;;
    esac
done
[[ ${#HOSTS[@]} -gt 0 ]] || { printf "ERROR: name at least one --host, or --all.\n"; exit 1; }

# DELIBERATELY no "refuse inside a Claude Code session" guard, unlike cc-update.sh.
# This script never touches the local install — it ships a binary and runs cc-update.sh
# on OTHER machines, and that script keeps its own Phase 0 refusal, which passes there
# because no session is running there. Refusing here would block the whole point:
# updating the fleet from a live session. A machine that IS running a session is still
# protected, by the per-host `live=` probe below, which refuses without --force.

_semver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
_probe()  { [[ -n "$1" && -x "$1" ]] || return 0
            timeout 5 "$1" --version 2>/dev/null </dev/null | _semver || true; }

# ── 1. Resolve the target. Nothing is contacted until this is a concrete number. ───────
if [[ "$TARGET_VERSION" == "latest" ]]; then
    printf "Resolving latest from the npm registry...\n"
    TARGET_VERSION=$(npm view @anthropic-ai/claude-code version 2>/dev/null | _semver || true)
fi
if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf "ERROR: target '%s' is not a concrete x.y.z version.\n" "$TARGET_VERSION"
    exit 1
fi
printf "Target: %s\n" "$TARGET_VERSION"

# ── 2. Stage and VERIFY the binary here, before any machine is touched. ───────────────
STAGE_DIR=""
cleanup() { [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]] && rm -rf "$STAGE_DIR"; }
trap cleanup EXIT

if [[ -z "$BINARY_SRC" ]]; then
    STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ccfleet.XXXXXX")
    printf "Installing @anthropic-ai/claude-code@%s into a staging tree...\n" "$TARGET_VERSION"
    # `npm pack` is NOT enough — MEASURED 2026-09-23: the tarball's package/bin/claude.exe
    # is a 500-byte ASCII SHIM that prints "claude native binary not installed". The real
    # ~233 MB ELF arrives through the platform optional dependency
    # (@anthropic-ai/claude-code-linux-x64) that postinstall downloads, and bin/claude.exe
    # is then a hardlink to it. Only a real install produces a shippable binary.
    npm install --prefix "$STAGE_DIR" --no-audit --no-fund --loglevel=error \
        "@anthropic-ai/claude-code@${TARGET_VERSION}" >/dev/null 2>&1 \
        || { printf "ERROR: npm install failed for %s\n" "$TARGET_VERSION"; exit 1; }
    for _c in "$STAGE_DIR/node_modules/@anthropic-ai/claude-code/bin/claude.exe" \
              "$STAGE_DIR/node_modules/@anthropic-ai/claude-code/bin/claude"; do
        [[ -f "$_c" ]] && { BINARY_SRC="$_c"; break; }
    done
    [[ -n "$BINARY_SRC" ]] || { printf "ERROR: no claude binary under the staged node_modules.\n"; exit 1; }
fi

chmod +x "$BINARY_SRC" 2>/dev/null || true
SRC_ARCH=$(file -b "$BINARY_SRC" 2>/dev/null | grep -oE 'x86-64|aarch64|arm64' | head -1 || true)
[[ -n "$SRC_ARCH" ]] || SRC_ARCH="x86-64"   # a shell stand-in in tests has no ELF header
SRC_VERSION=$(_probe "$BINARY_SRC")
printf "Source: %s (%s) reports %s\n" "$BINARY_SRC" "$SRC_ARCH" "${SRC_VERSION:-<nothing>}"
if [[ "$SRC_VERSION" != "$TARGET_VERSION" ]]; then
    printf "ERROR: the source binary reports '%s', not %s — REFUSING. Nothing was shipped.\n" \
        "${SRC_VERSION:-<nothing>}" "$TARGET_VERSION"
    # The most likely cause, named rather than left to be rediscovered.
    if [[ "$(stat -c%s "$BINARY_SRC" 2>/dev/null || echo 0)" -lt 1000000 ]]; then
        printf "       It is %s bytes — that is the npm SHIM, not the native binary.\n" \
            "$(stat -c%s "$BINARY_SRC" 2>/dev/null || echo '?')"
        printf "       postinstall did not fetch @anthropic-ai/claude-code-<platform>; reinstall\n"
        printf "       without --ignore-scripts/--omit=optional, or pass a real --binary.\n"
    fi
    exit 1
fi

# ── 3. Per host ───────────────────────────────────────────────────────────────────────
# The probe is one round trip and carries a marker so a stubbed transport can answer it.
PROBE_SCRIPT='# CCPROBE
m="$HOME/.cc-mirror/mclaude"
if [ -f "$m/npm/node_modules/@anthropic-ai/claude-code/package.json" ]; then l=npm; else l=native; fi
v=$("$HOME/.local/bin/mclaude" --version 2>/dev/null </dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
echo "arch=$(uname -m)"
echo "layout=$l"
echo "version=${v:-unknown}"
echo "live=$(ps -eo args | grep -F "cc-mirror/mclaude" | grep -v -F "grep" | grep -v -F "CCPROBE" | wc -l)"'

declare -a RESULTS=()
FAILED=0

for host in "${HOSTS[@]}"; do
    printf "\n━━━ %s ━━━\n" "$host"
    probe=$("$SSH" "${SSH_OPTS[@]}" "$host" "$PROBE_SCRIPT" 2>/dev/null || true)
    h_arch=$(sed -n 's/^arch=//p'    <<< "$probe" | head -1)
    h_layout=$(sed -n 's/^layout=//p' <<< "$probe" | head -1)
    h_ver=$(sed -n 's/^version=//p'  <<< "$probe" | head -1)
    h_live=$(sed -n 's/^live=//p'    <<< "$probe" | head -1)
    if [[ -z "$h_arch" || -z "$h_layout" ]]; then
        printf "  UNREACHABLE — no probe answer. Skipped.\n"
        RESULTS+=("$host|unreachable|-"); FAILED=$((FAILED + 1)); continue
    fi
    printf "  probe: arch=%s layout=%s version=%s live=%s\n" "$h_arch" "$h_layout" "$h_ver" "${h_live:-?}"

    # arch — never ship an x86-64 ELF to something else
    case "$h_arch" in
        x86_64|amd64) : ;;
        *) if [[ "$h_layout" == "native" ]]; then
               printf "  REFUSED: arch %s does not match the %s binary.\n" "$h_arch" "$SRC_ARCH"
               RESULTS+=("$host|refused: arch $h_arch|$h_ver"); FAILED=$((FAILED + 1)); continue
           fi ;;
    esac

    # Version-equal is NOT the same as correctly configured: deck2 sat at the target with
    # the fleet update-checker missing from its launcher, so nothing would have told anyone
    # it had begun drifting. Ship the ~15 KB wrapper and let it repair the config — but
    # never the 233 MB binary. --skip-npm makes an install impossible even if the remote
    # disagrees with our probe.
    if [[ "$h_ver" == "$TARGET_VERSION" ]]; then
        if $DRY_RUN; then
            printf "  [dry-run] already at %s — would verify configuration only.\n" "$h_ver"
            RESULTS+=("$host|dry-run (config)|$h_ver"); continue
        fi
        printf "  already at %s — verifying configuration (no binary shipped)...\n" "$h_ver"
        "$SSH" "${SSH_OPTS[@]}" "$host" "mkdir -p ~/$STAGING" >/dev/null 2>&1 || true
        if "$SCP" "${SSH_OPTS[@]}" -q "$SCRIPT_DIR/cc-update.sh" "$SCRIPT_DIR/cc-install-invariants.sh" "$host:~/$STAGING/"; then
            "$SSH" "${SSH_OPTS[@]}" "$host" \
                "bash ~/$STAGING/cc-update.sh --version $TARGET_VERSION --skip-npm" 2>&1 \
                | grep -E 'update-checker|FOREIGN|RESULT:|FAIL' | sed 's/^/    /' || true
            "$SSH" "${SSH_OPTS[@]}" "$host" "rm -rf ~/$STAGING" >/dev/null 2>&1 || true
        else
            printf "    (could not ship the wrapper — configuration not verified)\n"
        fi
        RESULTS+=("$host|up to date|$h_ver"); continue
    fi

    if [[ "${h_live:-0}" -gt 0 ]] && ! $FORCE; then
        printf "  REFUSED: %s live Claude Code process(es) there. Use --force to override.\n" "$h_live"
        RESULTS+=("$host|refused: live session|$h_ver"); FAILED=$((FAILED + 1)); continue
    fi

    if $DRY_RUN; then
        if [[ "$h_layout" == "native" ]]; then
            printf "  [dry-run] would ship the binary + cc-update.sh, then run it --via binary: %s → %s\n" "$h_ver" "$TARGET_VERSION"
        else
            printf "  [dry-run] would ship cc-update.sh, then run the npm road: %s → %s\n" "$h_ver" "$TARGET_VERSION"
        fi
        RESULTS+=("$host|dry-run|$h_ver"); continue
    fi

    # Ship the CURRENT wrapper — a remote's own checkout may predate the hardening.
    "$SSH" "${SSH_OPTS[@]}" "$host" "mkdir -p ~/$STAGING" >/dev/null 2>&1 || true
    if ! "$SCP" "${SSH_OPTS[@]}" -q "$SCRIPT_DIR/cc-update.sh" "$SCRIPT_DIR/cc-install-invariants.sh" "$host:~/$STAGING/"; then
        printf "  FAILED: could not ship cc-update.sh\n"
        RESULTS+=("$host|ship failed|$h_ver"); FAILED=$((FAILED + 1)); continue
    fi

    if [[ "$h_layout" == "native" ]]; then
        printf "  shipping the binary (%s)...\n" "$(du -h "$BINARY_SRC" 2>/dev/null | cut -f1)"
        if ! "$SCP" "${SSH_OPTS[@]}" -q "$BINARY_SRC" "$host:~/$STAGING/claude.new"; then
            printf "  FAILED: could not ship the binary\n"
            RESULTS+=("$host|ship failed|$h_ver"); FAILED=$((FAILED + 1)); continue
        fi
        remote_cmd="bash ~/$STAGING/cc-update.sh --version $TARGET_VERSION --via binary --binary ~/$STAGING/claude.new"
    else
        remote_cmd="bash ~/$STAGING/cc-update.sh --version $TARGET_VERSION"
    fi

    printf "  running cc-update.sh there...\n"
    rc=0
    "$SSH" "${SSH_OPTS[@]}" "$host" "$remote_cmd" 2>&1 | sed 's/^/    /' || rc=$?
    [[ "${PIPESTATUS[0]:-0}" -eq 0 ]] || rc=1

    after=$("$SSH" "${SSH_OPTS[@]}" "$host" '# CCVERIFY
"$HOME/.local/bin/mclaude" --version 2>/dev/null </dev/null' 2>/dev/null | _semver || true)
    "$SSH" "${SSH_OPTS[@]}" "$host" "rm -rf ~/$STAGING" >/dev/null 2>&1 || true

    if [[ "$after" == "$TARGET_VERSION" ]]; then
        printf "  VERIFIED through the launcher: %s\n" "$after"
        RESULTS+=("$host|updated|$after")
    else
        printf "  FAILED: the launcher reports '%s', expected %s (cc-update.sh rolls back on its own)\n" "${after:-<nothing>}" "$TARGET_VERSION"
        RESULTS+=("$host|FAILED|${after:-unknown}"); FAILED=$((FAILED + 1))
    fi
done

printf "\n━━━ Summary (target %s) ━━━\n" "$TARGET_VERSION"
printf "%-8s %-22s %s\n" "HOST" "RESULT" "VERSION"
for r in "${RESULTS[@]}"; do
    IFS='|' read -r a b c <<< "$r"
    printf "%-8s %-22s %s\n" "$a" "$b" "$c"
done
[[ "$FAILED" -eq 0 ]] || { printf "\n%d host(s) not updated.\n" "$FAILED"; exit 1; }
