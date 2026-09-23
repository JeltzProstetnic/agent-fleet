#!/usr/bin/env bash
# cc-update.sh — the fleet's ONLY sanctioned Claude Code update path for a cc-mirror
# variant. Run from a plain shell AFTER /exit, never inside a session.
#
# What it guarantees (specs: setup/tests/test-cc-update.sh, test-cc-update-guard.sh):
#   1. The target is resolved to a concrete x.y.z FIRST ("latest" via `npm view`, never
#      passed on). A target below the installed version is refused — DOWNGRADE, both
#      numbers printed — unless --allow-downgrade. --dry-run shows the same verdict.
#   2. Phase 1 backs up npm/ (or native/), the launcher and variant.json.
#   3. The install runs via npm (npm layout); via --via binary (native layout: the ELF
#      from the npm tarball is verified, then swapped in — needs no node on the target,
#      which is why BOTH Decks can only be updated this way: measured 2026-09-23,
#      `bash -lc 'command -v node'` is EMPTY on deck and deck2); or via --via cc-mirror,
#      a PINNED cc-mirror through npx. Never a bare `cc-mirror` from PATH, never "latest".
#   4. variant.json claudeOrig is rewritten to the installed version. Left at its
#      creation-time value, any cc-mirror re-provision reinstalls THAT version — measured
#      2026-09-23: claudeOrig=2.1.1 (unchanged since 2026-02-09) turned 2.1.274 into 2.1.1.
#   5. The launcher's exec line is rewritten to the new entry point and the fleet
#      update-checker is wired in before it (when the fleet repo exists under $HOME).
#   6. Post-condition: cc-install-invariants.sh --expect-version <target>. On failure the
#      Phase 1 backup is restored, ROLLED BACK is printed and the exit is non-zero.
#      Exit 0 means VERIFIED — never "the installer returned 0".
#   7. After a verified update the last-known-good snapshot is written.
#
# Paths are $HOME-anchored on purpose: CC_MIRROR_DIR/CONFIG_REPO are exported into every
# shell a session spawns, and honouring them here would let a sandboxed test reach the
# live install. The launcher line written in Phase 5 resolves CONFIG_REPO at ITS runtime.
set -euo pipefail

MIRROR_DIR="$HOME/.cc-mirror/mclaude"
NPM_DIR="$MIRROR_DIR/npm"
LAUNCHER="$HOME/.local/bin/mclaude"
VARIANT_JSON="$MIRROR_DIR/variant.json"
CC_PKG="$NPM_DIR/node_modules/@anthropic-ai/claude-code"
NATIVE_DIR="$MIRROR_DIR/native"
VARIANT_NAME="mclaude"

# The ONE cc-mirror version the --via cc-mirror road may run. 2.1.0 is the release whose
# variant writer the fleet has measured (native layout; see update-checker.sh). The
# Windows-side 1.6.2 that a bare `cc-mirror` resolved to on 2026-09-23 has no
# --claude-version at all and re-provisions from the creation-time pin. Bump here only.
CC_MIRROR_PIN="2.1.0"

# What Phase 5 inserts before the launcher's exec line (identical to the by-hand line).
UPDATE_CHECKER_BLOCK='# Fleet update check — daily-gated inside the script (wired by cc-update.sh)
[[ -t 1 && "$*" != *"--output-format"* && -f "${CONFIG_REPO:-$HOME/cfg-agent-fleet}/setup/scripts/update-checker.sh" ]] && bash "${CONFIG_REPO:-$HOME/cfg-agent-fleet}/setup/scripts/update-checker.sh" || true'

TARGET_VERSION="latest"
DRY_RUN=false
SKIP_NPM=false
ALLOW_DOWNGRADE=false
ACCEPT_UNREQUESTED=false
VIA="auto"
BINARY_SRC=""

usage() {
    printf "Usage: %s [--version <x.y.z|latest>] [--via npm|binary|cc-mirror]\n" "$(basename "$0")"
    printf "       %*s [--binary <path>] [--allow-downgrade]\n" "${#0}" ""
    printf "       %*s [--accept-unrequested] [--dry-run] [--skip-npm]\n" "${#0}" ""
    printf "       Run OUTSIDE of a running CC session (after /exit).\n"
    printf "       --via binary      native-layout machines: install <path> as native/claude.\n"
    printf "                         Verified against --version BEFORE the swap; needs no node\n"
    printf "                         on this machine. Implied when --binary is given.\n"
    printf "       --via cc-mirror   native-layout machines WITH node/npx: runs\n"
    printf "                         npx -y cc-mirror@%s update %s --claude-version <x.y.z> --no-tweak\n" "$CC_MIRROR_PIN" "$VARIANT_NAME"
    printf "       --allow-downgrade  install a target BELOW the current version (refused otherwise)\n"
    printf "       --accept-unrequested  keep skills/teamModeEnabled the installer changed (rolled back otherwise)\n"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) TARGET_VERSION="$2"; shift 2 ;;
        --via) VIA="$2"; shift 2 ;;
        --binary) BINARY_SRC="$2"; shift 2 ;;
        --variant) VARIANT_NAME="$2"; shift 2 ;;
        --allow-downgrade) ALLOW_DOWNGRADE=true; shift ;;
        --accept-unrequested) ACCEPT_UNREQUESTED=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-npm) SKIP_NPM=true; shift ;;
        -h|--help) usage ;;
        *) printf "Unknown option: %s\n" "$1"; usage ;;
    esac
done
case "$VIA" in auto|npm|binary|cc-mirror) ;; *) printf "ERROR: --via must be npm, binary or cc-mirror\n"; exit 1 ;; esac
# --binary implies the binary road: a node-less machine must never fall through to npx.
[[ -n "$BINARY_SRC" && "$VIA" == "auto" ]] && VIA="binary"
if [[ "$VIA" == "binary" ]]; then
    if [[ -z "$BINARY_SRC" ]]; then
        printf "ERROR: --via binary needs --binary <path> — the source binary to install.\n"
        exit 1
    fi
    if [[ ! -f "$BINARY_SRC" ]]; then
        printf "ERROR: --binary %s does not exist.\n" "$BINARY_SRC"
        exit 1
    fi
fi

# Phase 0: Refuse if inside CC
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    printf "ERROR: Running inside a Claude Code session (CLAUDE_CONFIG_DIR is set).\n"
    printf "       Exit CC first, then run this script from a plain shell.\n"
    exit 1
fi

_semver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
_ver_lt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }
_json_field() { grep -o "\"$2\": *\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' || true; }
_probe() {  # _probe <binary> → x.y.z from --version, bounded, empty on failure
    [[ -n "$1" && -x "$1" ]] || return 0
    if command -v timeout >/dev/null 2>&1; then timeout 5 "$1" --version 2>/dev/null </dev/null | _semver || true
    else "$1" --version 2>/dev/null </dev/null | _semver || true; fi
}

# Layout: npm (WSL/VPS: npm/node_modules/.../bin/claude.exe) or native (Deck/NUC/office: native/claude)
if [[ -f "$CC_PKG/package.json" ]]; then LAYOUT="npm"; else LAYOUT="native"; fi
if [[ "$VIA" == "auto" ]]; then
    if [[ "$LAYOUT" == "npm" ]]; then VIA="npm"; else VIA="cc-mirror"; fi
fi

# Detect current version
CURRENT_VERSION=""
if [[ "$LAYOUT" == "npm" ]]; then
    CURRENT_VERSION=$(python3 -c "import json; print(json.load(open('$CC_PKG/package.json'))['version'])")
else
    _bin=$(_json_field "$VARIANT_JSON" binaryPath); [[ -x "$_bin" ]] || _bin="$NATIVE_DIR/claude"
    CURRENT_VERSION=$(_probe "$_bin")
    [[ -n "$CURRENT_VERSION" ]] || CURRENT_VERSION=$(_json_field "$VARIANT_JSON" claudeOrig | _semver)
fi
if [[ -z "$CURRENT_VERSION" ]]; then
    printf "ERROR: No CC installation found at %s (no package.json, no runnable native/claude).\n" "$CC_PKG"
    exit 1
fi
printf "Current version: %s (%s layout)\n" "$CURRENT_VERSION" "$LAYOUT"

# Resolve target version — to a concrete number, BEFORE anything else happens
if [[ "$TARGET_VERSION" == "latest" ]]; then
    printf "Resolving latest version...\n"
    TARGET_VERSION=$(npm view @anthropic-ai/claude-code version 2>/dev/null | _semver || true)
    if [[ -z "$TARGET_VERSION" ]]; then
        printf "ERROR: could not resolve 'latest' from the npm registry — pass --version <x.y.z>.\n"
        exit 1
    fi
fi
if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf "ERROR: target '%s' is not a concrete x.y.z version.\n" "$TARGET_VERSION"
    exit 1
fi
printf "Target version:  %s (via %s)\n" "$TARGET_VERSION" "$VIA"

# The binary road, validated BEFORE Phase 1. Handover 2026-09-23 step 4: the source must
# print the intended version or we abort — a swap-then-check leaves a node-less Deck dead
# with no way to run the thing that would tell you so.
if [[ "$VIA" == "binary" ]]; then
    if [[ "$LAYOUT" != "native" ]]; then
        printf "ERROR: --via binary is for native-layout installs; this one is %s layout.\n" "$LAYOUT"
        exit 1
    fi
    chmod +x "$BINARY_SRC" 2>/dev/null || true
    SRC_VERSION=$(_probe "$BINARY_SRC")
    printf "Source binary:   %s → reports %s\n" "$BINARY_SRC" "${SRC_VERSION:-<nothing>}"
    if [[ "$SRC_VERSION" != "$TARGET_VERSION" ]]; then
        printf "ERROR: the source binary reports '%s', not the requested %s — REFUSING to swap.\n" \
            "${SRC_VERSION:-<nothing>}" "$TARGET_VERSION"
        printf "       Nothing was touched; the installed binary is still %s.\n" "$CURRENT_VERSION"
        exit 1
    fi
fi

# Downgrade guard — refuse a lower target; --allow-downgrade is the only way through
if _ver_lt "$TARGET_VERSION" "$CURRENT_VERSION"; then
    if $ALLOW_DOWNGRADE; then
        printf "DOWNGRADE allowed explicitly: %s → %s (--allow-downgrade)\n" "$CURRENT_VERSION" "$TARGET_VERSION"
    else
        printf "\nDOWNGRADE refused: target %s is BELOW the installed %s.\n" "$TARGET_VERSION" "$CURRENT_VERSION"
        printf "  This is what the 2026-09-23 reset looked like from the inside (2.1.274 → 2.1.1, exit 0).\n"
        printf "  If it is deliberate, re-run with --allow-downgrade. Nothing was touched.\n"
        exit 3
    fi
fi

# Post-condition script: beside this file, then the fleet repos under $HOME
INVARIANTS=""
for _c in "${CC_INSTALL_INVARIANTS:-}" "$(dirname "$0")/cc-install-invariants.sh" \
          "$HOME/cfg-agent-fleet/setup/scripts/cc-install-invariants.sh" \
          "$HOME/agent-fleet/setup/scripts/cc-install-invariants.sh"; do
    if [[ -n "$_c" && -f "$_c" ]]; then INVARIANTS="$_c"; break; fi
done

# run_invariants [args…] — prints the report indented; returns its rc, 2 when unavailable.
# Always call in a condition context (`if`/`||`): set -e must not abort on its FAIL exit.
run_invariants() {
    if [[ -z "$INVARIANTS" ]]; then
        printf "  WARNING: cc-install-invariants.sh not found (beside this script, ~/cfg-agent-fleet, ~/agent-fleet) — inline checks only.\n"
        return 2
    fi
    CC_MIRROR_DIR="$MIRROR_DIR" CC_LAUNCHER="$LAUNCHER" bash "$INVARIANTS" "$@" 2>&1 | sed 's/^/  /'
    return "${PIPESTATUS[0]}"
}

# Detect entry point (needed for dry-run display and actual update)
# Post-2.1.113: native binary (bin/claude.exe or bin/claude). Pre-2.1.113: cli.js. Native layout: native/claude.
detect_entry_point() {
    if [[ -f "$CC_PKG/bin/claude.exe" ]]; then ENTRY_POINT="$CC_PKG/bin/claude.exe"; ENTRY_TYPE="native"
    elif [[ -f "$CC_PKG/bin/claude" ]]; then ENTRY_POINT="$CC_PKG/bin/claude"; ENTRY_TYPE="native"
    elif [[ -f "$CC_PKG/cli.js" ]]; then ENTRY_POINT="$CC_PKG/cli.js"; ENTRY_TYPE="node"
    elif [[ -f "$NATIVE_DIR/claude" ]]; then ENTRY_POINT="$NATIVE_DIR/claude"; ENTRY_TYPE="native"
    else ENTRY_POINT=""; ENTRY_TYPE="unknown"; fi
}
detect_entry_point

# Dry-run exit
if $DRY_RUN; then
    printf "\n[dry-run] Would update %s → %s via %s\n" "$CURRENT_VERSION" "$TARGET_VERSION" "$VIA"
    if [[ "$VIA" == "binary" ]]; then
        printf "[dry-run] Installer:     cp %s → %s (verified %s, atomic mv)\n" "$BINARY_SRC" "$NATIVE_DIR/claude" "$SRC_VERSION"
    elif [[ "$VIA" == "cc-mirror" ]]; then
        printf "[dry-run] Installer:     npx -y cc-mirror@%s update %s --claude-version %s --no-tweak\n" "$CC_MIRROR_PIN" "$VARIANT_NAME" "$TARGET_VERSION"
    else
        printf "[dry-run] npm install in: %s\n" "$NPM_DIR"
    fi
    printf "[dry-run] Current entry: %s (%s)\n" "$ENTRY_POINT" "$ENTRY_TYPE"
    printf "[dry-run] Launcher:      %s (exec line rewritten; update-checker wired if the fleet repo exists under \$HOME)\n" "$LAUNCHER"
    printf "[dry-run] variant.json:  %s (binaryPath, npmVersion, claudeOrig → %s)\n" "$VARIANT_JSON" "$TARGET_VERSION"
    printf "[dry-run] Post-condition: %s --expect-version %s → ROLLED BACK on failure\n" "${INVARIANTS:-<cc-install-invariants.sh not found>}" "$TARGET_VERSION"
    exit 0
fi

# wire_update_checker — insert UPDATE_CHECKER_BLOCK before the exec line, once, only when
# a fleet repo carrying update-checker.sh exists under $HOME (a line pointing nowhere is
# a dead line, and a sandboxed test HOME has no repo). Measured 2026-09-23: the live
# launcher had ZERO references to it and its marker read 2026-02-09 — it had never run.
wire_update_checker() {
    local _n
    # Match the FLEET block, not the bare filename. MEASURED on deck2 2026-09-23: a
    # cc-mirror-generated line calling ~/.cc-mirror/mclaude/scripts/update-checker.sh
    # satisfied a bare-filename guard, so the fleet checker was never wired there and the
    # machine drifted 142 releases while looking correctly configured. CONFIG_REPO appears
    # only in our own block.
    if grep -q 'CONFIG_REPO.*update-checker\.sh' "$LAUNCHER"; then
        printf "  update-checker already wired into the launcher\n"; return 0
    fi
    if grep -q 'update-checker\.sh' "$LAUNCHER"; then
        printf "  NOTE: the launcher references a FOREIGN update-checker; wiring the fleet one alongside it\n"
    fi
    if [[ ! -f "$HOME/cfg-agent-fleet/setup/scripts/update-checker.sh" && ! -f "$HOME/agent-fleet/setup/scripts/update-checker.sh" ]]; then
        printf "  update-checker NOT wired: no fleet repo with setup/scripts/update-checker.sh under %s\n" "$HOME"; return 0
    fi
    _n=$(grep -n -E '^[[:space:]]*exec ' "$LAUNCHER" | tail -1 | cut -d: -f1)
    if [[ -z "$_n" ]]; then printf "  update-checker NOT wired: no exec line in the launcher\n"; return 0; fi
    { head -n $((_n - 1)) "$LAUNCHER"; printf '%s\n' "$UPDATE_CHECKER_BLOCK"; tail -n +"$_n" "$LAUNCHER"; } > "${LAUNCHER}.tmp"
    mv "${LAUNCHER}.tmp" "$LAUNCHER"
    chmod +x "$LAUNCHER"
    printf "  update-checker wired into the launcher (before the exec line)\n"
}

# Already up to date — still verify, so "up to date" can never mean "up to date and dead"
if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
    printf "\nAlready up to date at %s.\n" "$CURRENT_VERSION"
    # "up to date" must also mean "correctly wired". MEASURED on deck2 2026-09-23: it sat
    # at the right version with the fleet update-checker absent, so nothing would ever have
    # told anyone it had started drifting again.
    wire_update_checker
    _rc=0; run_invariants --write-snapshot || _rc=$?
    if [[ "$_rc" -eq 1 ]]; then
        printf "Already up to date, but the install FAILS its invariants (above) — not exit 0.\n"
        exit 1
    fi
    exit 0
fi

printf "\nUpdating %s → %s\n\n" "$CURRENT_VERSION" "$TARGET_VERSION"

# Pre-flight: record the state we are leaving (last-known-good if it passes) — informational
printf "Pre-flight: state before the update\n"
run_invariants --write-snapshot || true

# Skills present before the installer runs — a rollback removes what it added
PRE_SKILLS=""
for _d in "$MIRROR_DIR/config/skills"/*/; do
    [[ -d "$_d" ]] && PRE_SKILLS="${PRE_SKILLS}$(basename "$_d")"$'\n'
done

# rollback — restore the Phase 1 backup and undo installer side effects. Never exit 0 after.
rollback() {
    printf "\nRestoring the Phase 1 backup (%s)...\n" "$BACKUP_SUFFIX"
    if [[ "$LAYOUT" == "npm" && -d "${NPM_DIR}${BACKUP_SUFFIX}" ]]; then
        { rm -rf "$NPM_DIR" && cp -a "${NPM_DIR}${BACKUP_SUFFIX}" "$NPM_DIR"; } || printf "  ERROR: npm/ restore failed — backup at %s\n" "${NPM_DIR}${BACKUP_SUFFIX}"
    fi
    if [[ "$LAYOUT" == "native" && -d "${NATIVE_DIR}${BACKUP_SUFFIX}" ]]; then
        { rm -rf "$NATIVE_DIR" && cp -a "${NATIVE_DIR}${BACKUP_SUFFIX}" "$NATIVE_DIR"; } || printf "  ERROR: native/ restore failed — backup at %s\n" "${NATIVE_DIR}${BACKUP_SUFFIX}"
    fi
    [[ -f "${LAUNCHER}${BACKUP_SUFFIX}" ]] && cp -a "${LAUNCHER}${BACKUP_SUFFIX}" "$LAUNCHER"
    [[ -f "${VARIANT_JSON}${BACKUP_SUFFIX}" ]] && cp -a "${VARIANT_JSON}${BACKUP_SUFFIX}" "$VARIANT_JSON"
    local _d _n
    for _d in "$MIRROR_DIR/config/skills"/*/; do
        [[ -d "$_d" ]] || continue
        _n=$(basename "$_d")
        grep -qx "$_n" <<<"$PRE_SKILLS" || { rm -rf "$_d"; printf "  removed skill the installer added: %s\n" "$_n"; }
    done
    printf "ROLLED BACK to %s — the update did NOT happen; exit status is non-zero on purpose.\n" "$CURRENT_VERSION"
}

# Phase 1: Backup
BACKUP_SUFFIX="-backup-${CURRENT_VERSION}"
printf "Phase 1: Backup (%s)\n" "$BACKUP_SUFFIX"
if [[ "$LAYOUT" == "npm" ]]; then
    if [[ -d "${NPM_DIR}${BACKUP_SUFFIX}" ]]; then printf "  Backup already exists, skipping copy\n"
    else cp -a "$NPM_DIR" "${NPM_DIR}${BACKUP_SUFFIX}"; fi
elif [[ -d "$NATIVE_DIR" ]]; then
    if [[ -d "${NATIVE_DIR}${BACKUP_SUFFIX}" ]]; then printf "  Backup already exists, skipping copy\n"
    else cp -a "$NATIVE_DIR" "${NATIVE_DIR}${BACKUP_SUFFIX}"; fi
fi
[[ -f "$LAUNCHER" ]] && cp -a "$LAUNCHER" "${LAUNCHER}${BACKUP_SUFFIX}" || true
[[ -f "$VARIANT_JSON" ]] && cp -a "$VARIANT_JSON" "${VARIANT_JSON}${BACKUP_SUFFIX}" || true

# Phase 2: install — npm in place, or the pinned cc-mirror through npx. Never bare cc-mirror.
if $SKIP_NPM; then
    printf "Phase 2: install (SKIPPED — --skip-npm)\n"
elif [[ "$VIA" == "binary" ]]; then
    printf "Phase 2: installing verified binary → %s\n" "$NATIVE_DIR/claude"
    mkdir -p "$NATIVE_DIR"
    cp "$BINARY_SRC" "$NATIVE_DIR/claude.new" \
        || { printf "  copy into %s failed\n" "$NATIVE_DIR"; rollback; exit 1; }
    chmod +x "$NATIVE_DIR/claude.new"
    mv -f "$NATIVE_DIR/claude.new" "$NATIVE_DIR/claude" \
        || { printf "  atomic swap failed\n"; rollback; exit 1; }
elif [[ "$VIA" == "cc-mirror" ]]; then
    printf "Phase 2: npx -y cc-mirror@%s update %s --claude-version %s --no-tweak\n" "$CC_MIRROR_PIN" "$VARIANT_NAME" "$TARGET_VERSION"
    npx -y "cc-mirror@${CC_MIRROR_PIN}" update "$VARIANT_NAME" --claude-version "$TARGET_VERSION" --no-tweak \
        || { printf "  installer exited non-zero\n"; rollback; exit 1; }
else
    printf "Phase 2: npm install @anthropic-ai/claude-code@%s\n" "$TARGET_VERSION"
    (cd "$NPM_DIR" && npm install "@anthropic-ai/claude-code@${TARGET_VERSION}") \
        || { printf "  npm install exited non-zero\n"; rollback; exit 1; }
fi

# Phase 3: Verify what the installer left behind — before touching launcher or variant.json
detect_entry_point
NEW_VERSION=""
if [[ "$LAYOUT" == "npm" && -f "$CC_PKG/package.json" ]]; then
    NEW_VERSION=$(python3 -c "import json; print(json.load(open('$CC_PKG/package.json'))['version'])" 2>/dev/null || true)
fi
[[ -n "$NEW_VERSION" ]] || NEW_VERSION=$(_probe "$ENTRY_POINT")
if [[ "$NEW_VERSION" != "$TARGET_VERSION" ]]; then
    printf "ERROR: Expected %s but the install reports %s (installer exit status was 0 — that means nothing)\n" "$TARGET_VERSION" "${NEW_VERSION:-<none>}"
    rollback
    exit 1
fi
printf "Phase 3: Verified installed version → %s\n" "$NEW_VERSION"

# Phase 4: Entry point after install (binary may have changed)
if [[ -z "$ENTRY_POINT" ]]; then
    printf "ERROR: No entry point found (checked bin/claude.exe, bin/claude, cli.js, native/claude)\n"
    rollback
    exit 1
fi
printf "Phase 4: Entry point → %s (%s)\n" "$ENTRY_POINT" "$ENTRY_TYPE"

# Phase 5: Update launcher — exec line to the new entry point, update-checker wired before it
if [[ ! -f "$LAUNCHER" ]]; then
    printf "ERROR: Launcher not found at %s\n" "$LAUNCHER"
    rollback
    exit 1
fi
printf "Phase 5: Updating launcher\n"
case "$ENTRY_TYPE" in
    native) NEW_EXEC_LINE="exec \"${ENTRY_POINT}\" \"\$@\"" ;;
    node)   NEW_EXEC_LINE="exec node \"${ENTRY_POINT}\" \"\$@\"" ;;
esac
head -n -1 "$LAUNCHER" > "${LAUNCHER}.tmp"
printf '%s\n' "$NEW_EXEC_LINE" >> "${LAUNCHER}.tmp"
mv "${LAUNCHER}.tmp" "$LAUNCHER"
chmod +x "$LAUNCHER"

wire_update_checker

# Phase 6: Update variant.json — binaryPath, npmVersion (npm layout), updatedAt, and the
# claudeOrig pin: the value a re-provision would install must be the version we verified.
printf "Phase 6: Updating variant.json (claudeOrig → %s)\n" "$NEW_VERSION"
python3 -c "
import json, datetime
with open('$VARIANT_JSON') as f:
    v = json.load(f)
v['binaryPath'] = '$ENTRY_POINT'
if '$LAYOUT' == 'npm':
    v['npmVersion'] = '$NEW_VERSION'
    v['claudeOrig'] = 'npm:' + v.get('npmPackage', '@anthropic-ai/claude-code') + '@$NEW_VERSION'
else:
    v['claudeOrig'] = 'native:$NEW_VERSION'
v['updatedAt'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
with open('$VARIANT_JSON', 'w') as f:
    json.dump(v, f, indent=2)
    f.write('\n')
"

# Phase 7: TweakCC note
printf "Phase 7: TweakCC status\n"
if [[ "$ENTRY_TYPE" == "native" ]]; then
    printf "  Native binary — code patches do not apply. System prompt patches still work.\n"
else
    printf "  Legacy cli.js — code patches may apply via tweakcc.\n"
fi

# Phase 8: Verify binary — the file the launcher will exec must report the target
printf "Phase 8: Verify binary\n"
REPORTED_VERSION=$("$ENTRY_POINT" --version 2>/dev/null </dev/null || true)
[[ -n "$REPORTED_VERSION" || "$ENTRY_TYPE" != "node" ]] || REPORTED_VERSION=$(node "$ENTRY_POINT" --version 2>/dev/null </dev/null || true)
if [[ "$REPORTED_VERSION" != *"$TARGET_VERSION"* ]]; then
    printf "  ERROR: %s --version reports '%s', expected %s\n" "$ENTRY_POINT" "${REPORTED_VERSION:-<empty>}" "$TARGET_VERSION"
    rollback
    exit 1
fi
printf "  Binary reports: %s\n" "$REPORTED_VERSION"

# Phase 9: Post-condition — the install as a whole, against the last-known-good snapshot.
# Exit 0 below means this passed; a FAIL restores the backup.
printf "Phase 9: Post-condition (cc-install-invariants.sh --expect-version %s)\n" "$TARGET_VERSION"
_pc_args=(--expect-version "$TARGET_VERSION" --write-snapshot)
$ALLOW_DOWNGRADE && _pc_args+=(--allow-downgrade)
$ACCEPT_UNREQUESTED && _pc_args+=(--allow-unrequested)
_pc_rc=0
run_invariants "${_pc_args[@]}" || _pc_rc=$?
case "$_pc_rc" in
    0) printf "  VERIFIED: the install is %s and every invariant holds; snapshot written.\n" "$TARGET_VERSION" ;;
    2) printf "  VERIFIED by inline checks only (package.json, entry point, binary --version) — no snapshot written.\n" ;;
    *) printf "  POST-CONDITION FAILED (rc=%s) — the installer's exit status was 0 and is not evidence of anything.\n" "$_pc_rc"
       rollback
       exit 1 ;;
esac

printf "\n━━━ Update complete: %s → %s ━━━\n\n" "$CURRENT_VERSION" "$NEW_VERSION"
printf "Next steps:\n"
printf "  1. Start mclaude and verify it loads correctly\n"
printf "  2. Check hooks and MCP servers still work\n"
printf "  3. Commit variant.json if everything looks good\n"
printf "\nRollback:\n"
if [[ "$LAYOUT" == "npm" ]]; then printf "  cp -a '%s' '%s'\n" "${NPM_DIR}${BACKUP_SUFFIX}" "$NPM_DIR"
else printf "  cp -a '%s' '%s'\n" "${NATIVE_DIR}${BACKUP_SUFFIX}" "$NATIVE_DIR"; fi
printf "  cp -a '%s' '%s'\n" "${LAUNCHER}${BACKUP_SUFFIX}" "$LAUNCHER"
printf "  cp -a '%s' '%s'\n" "${VARIANT_JSON}${BACKUP_SUFFIX}" "$VARIANT_JSON"
