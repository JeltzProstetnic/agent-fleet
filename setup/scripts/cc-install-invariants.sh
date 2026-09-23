#!/usr/bin/env bash
# cc-install-invariants.sh — local, network-free post-condition check for the Claude Code
# install under ~/.cc-mirror/<variant>. Reads the FILESYSTEM ONLY: never npm, never
# cc-mirror, never the network. Spec: setup/tests/test-cc-install-invariants.sh.
#
# Why (measured on WSL 2026-09-23): `cc-mirror update mclaude --claude-version latest
# --no-tweak` resolved to a Windows-side cc-mirror 1.6.2 that does not know the flag,
# re-provisioned from variant.json's creation-time pin (claudeOrig=2.1.1, unchanged since
# 2026-02-09), rewrote the launcher to `exec node …/cli.js` (a file that no longer exists),
# re-asserted teamModeEnabled, reinstalled the orchestration/task-manager skills — and
# exited 0. The daily `npm view` gate (check 4.6) had already been spent that morning, so
# no session that day could have said a word. Every check below is one of those shapes.
#
# Usage: cc-install-invariants.sh [--expect-version X.Y.Z] [--write-snapshot] [--force]
#                                 [--allow-downgrade] [--allow-unrequested]
#   --expect-version    FAIL EXPECT unless the installed version is exactly X.Y.Z
#   --write-snapshot    record the measured state as last-known-good — ONLY when the run
#                       has no FAIL line, so a broken install can never become the baseline
#   --force             with --write-snapshot: write despite FAILs (explicit acceptance,
#                       e.g. after a deliberate teamModeEnabled flip)
#   --allow-downgrade   installed < snapshot is WARN, not FAIL DOWNGRADE (cc-update.sh
#                       passes this through from its own --allow-downgrade)
#   --allow-unrequested teamModeEnabled / skill-set drift is WARN, not FAIL UNREQUESTED
# Env (all optional):
#   CC_MIRROR_DIR            $HOME/.cc-mirror/mclaude
#   CC_LAUNCHER              $HOME/.local/bin/mclaude
#   CC_INSTALL_SNAPSHOT      ${XDG_CACHE_HOME:-$HOME/.cache}/cfg-agent-fleet/cc-install.snapshot
#   CC_SETTINGS_TEMPLATE     <repo>/setup/config/settings.json   (the env-key policy)
#   CC_SETTINGS_OVERLAY_DIR  <repo>/setup/config/machines        (per-machine env-key policy)
#   CC_VAULT_MANAGE          <repo>/secrets/vault-manage.sh      (keys vault deploy injects)
# Output: one line per check — OK: / FAIL: <TAG> / WARN: / INFO: — every line carries the
# MEASURED values, never a restated assertion. Tags: DOWNGRADE RANGE VARIANT LAUNCHER
# UNREQUESTED SETTINGS EXPECT UNKNOWN. Exit 1 on any FAIL, else 0.
# Snapshot format (key=value): version=, teamModeEnabled=, skills=<csv, sorted>.
# With no snapshot the run is a baseline: DOWNGRADE/UNREQUESTED cannot fire.

set -uo pipefail   # deliberately NOT -e: every probe may fail; FAILs are counted, not fatal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIRROR="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"
LAUNCHER="${CC_LAUNCHER:-$HOME/.local/bin/mclaude}"
SNAPSHOT="${CC_INSTALL_SNAPSHOT:-${XDG_CACHE_HOME:-$HOME/.cache}/cfg-agent-fleet/cc-install.snapshot}"
TEMPLATE="${CC_SETTINGS_TEMPLATE:-$REPO_ROOT/setup/config/settings.json}"
OVERLAY_DIR="${CC_SETTINGS_OVERLAY_DIR:-$REPO_ROOT/setup/config/machines}"
VAULT_MANAGE="${CC_VAULT_MANAGE:-$REPO_ROOT/secrets/vault-manage.sh}"
PKG_JSON="$MIRROR/npm/node_modules/@anthropic-ai/claude-code/package.json"
NPM_ROOT_PKG="$MIRROR/npm/package.json"
VARIANT="$MIRROR/variant.json"
LIVE_SETTINGS="$MIRROR/config/settings.json"
SKILLS_DIR="$MIRROR/config/skills"

EXPECT="" WRITE=0 FORCE=0 ALLOW_DOWNGRADE=0 ALLOW_UNREQUESTED=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect-version)    EXPECT="${2:-}"; shift 2 ;;
        --write-snapshot)    WRITE=1; shift ;;
        --force)             FORCE=1; shift ;;
        --allow-downgrade)   ALLOW_DOWNGRADE=1; shift ;;
        --allow-unrequested) ALLOW_UNREQUESTED=1; shift ;;
        -h|--help)           sed -n '14,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 64 ;;
    esac
done

FAILS=0
ok()   { printf 'OK: %s\n' "$*"; }
info() { printf 'INFO: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
fail() { local tag="$1"; shift; printf 'FAIL: %s %s\n' "$tag" "$*"; FAILS=$((FAILS + 1)); }

_semver()     { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
_field()      { [[ -f "$1" ]] || return 0; grep -o "\"$2\": *\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' || true; }
_bool_field() { [[ -f "$1" ]] || return 0; grep -oE "\"$2\": *(true|false)" "$1" 2>/dev/null | head -1 | grep -oE 'true|false' || true; }
_ver_lt()     { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }
_probe() {  # _probe <binary> → x.y.z from `--version`, bounded, empty on any failure
    [[ -n "$1" && -x "$1" ]] || return 0
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$1" --version 2>/dev/null </dev/null | _semver || true
    else
        "$1" --version 2>/dev/null </dev/null | _semver || true
    fi
}
_env_keys() {  # _env_keys <settings.json> → one env key per line (python3; empty otherwise)
    [[ -f "$1" ]] && command -v python3 >/dev/null 2>&1 || return 0
    python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print("\n".join(sorted((d.get("env") or {}).keys())))
except Exception:
    pass' "$1" 2>/dev/null || true
}
_range_ok() {  # _range_ok <npm range> <version> — the subset of semver ranges npm writes
    local range="$1" ver="$2" op base
    case "$range" in ''|'*'|latest|x) return 0 ;; esac
    op="${range%%[0-9]*}"
    base=$(printf '%s' "$range" | _semver)
    [[ -n "$base" ]] || return 0
    case "$op" in
        '^')    ! _ver_lt "$ver" "$base" && [[ "${ver%%.*}" == "${base%%.*}" ]] ;;
        '~')    ! _ver_lt "$ver" "$base" && [[ "${ver%.*}" == "${base%.*}" ]] ;;
        '>=')   ! _ver_lt "$ver" "$base" ;;
        '>')    _ver_lt "$base" "$ver" ;;
        ''|'=') [[ "$ver" == "$base" ]] ;;
        *)      return 0 ;;
    esac
}
_exec_target() {  # _exec_target <exec line> → the file the launcher execs (strips `node`)
    local rest="${1#*exec }"
    rest="${rest#node }"
    rest="${rest#"${rest%%[! ]*}"}"
    if   [[ "$rest" == \"* ]]; then rest="${rest#\"}"; printf '%s' "${rest%%\"*}"
    elif [[ "$rest" == \'* ]]; then rest="${rest#\'}"; printf '%s' "${rest%%\'*}"
    else printf '%s' "${rest%%[[:space:]]*}"; fi
}

# ── 1. Installed version: package.json → binary --version → variant.json x.y.z ─────────
PKG_VER=""; [[ -f "$PKG_JSON" ]] && PKG_VER=$(_field "$PKG_JSON" version | _semver)
BIN_PATH=$(_field "$VARIANT" binaryPath)
if [[ -z "$BIN_PATH" || ! -x "$BIN_PATH" ]] && [[ -x "$MIRROR/native/claude" ]]; then BIN_PATH="$MIRROR/native/claude"; fi
BIN_VER=$(_probe "$BIN_PATH")
INSTALLED="$PKG_VER"; SOURCE="npm package.json ($PKG_JSON)"
if [[ -z "$INSTALLED" && -n "$BIN_VER" ]]; then INSTALLED="$BIN_VER"; SOURCE="binary --version ($BIN_PATH)"; fi
if [[ -z "$INSTALLED" ]]; then
    for _k in nativeVersion claudeOrig npmVersion; do
        _v=$(_field "$VARIANT" "$_k" | _semver)
        [[ -n "$_v" ]] && { INSTALLED="$_v"; SOURCE="variant.json $_k — UNVERIFIED, no package.json and no runnable binary"; break; }
    done
fi
if [[ -z "$INSTALLED" ]]; then
    fail UNKNOWN "installed version not determinable under $MIRROR — no $PKG_JSON, no runnable binary (variant.json binaryPath='${BIN_PATH:-<none>}', $MIRROR/native/claude), no x.y.z in variant.json. Nothing below can be trusted; probe by hand."
else
    ok "installed $INSTALLED (from $SOURCE)"
    [[ "$SOURCE" == variant.json* ]] && warn "version comes from variant.json alone; the binary that would actually run was not found"
fi
[[ -n "$PKG_VER" && -n "$BIN_VER" && "$PKG_VER" != "$BIN_VER" ]] && warn "package.json says $PKG_VER but $BIN_PATH --version reports $BIN_VER"

# ── 2. RANGE: the mirror's own npm/package.json range must admit the installed version ──
if [[ -f "$NPM_ROOT_PKG" && -n "$INSTALLED" ]]; then
    DECLARED=$(grep -o '"@anthropic-ai/claude-code": *"[^"]*"' "$NPM_ROOT_PKG" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/' || true)
    if [[ -z "$DECLARED" ]]; then
        info "npm/package.json declares no @anthropic-ai/claude-code dependency — nothing to compare"
    elif _range_ok "$DECLARED" "$INSTALLED"; then
        ok "installed $INSTALLED satisfies the declared dependency $DECLARED ($NPM_ROOT_PKG)"
    else
        fail RANGE "installed $INSTALLED is outside the dependency npm/package.json declares: $DECLARED ($NPM_ROOT_PKG) — the tree was replaced by something that did not go through npm install"
    fi
fi

# ── 3. VARIANT: variant.json must describe the install that is actually there ───────────
V_BIN=""
if [[ -f "$VARIANT" ]]; then
    V_NPM=$(_field "$VARIANT" npmVersion)
    if [[ -n "$V_NPM" && "$V_NPM" != latest && -n "$INSTALLED" ]]; then
        if [[ "$V_NPM" == "$INSTALLED" ]]; then ok "variant.json npmVersion $V_NPM matches the installed version"
        else fail VARIANT "variant.json npmVersion=$V_NPM but the installed version is $INSTALLED ($VARIANT)"; fi
    fi
    V_BIN=$(_field "$VARIANT" binaryPath)
    if [[ -z "$V_BIN" ]]; then warn "variant.json carries no binaryPath"
    elif [[ -x "$V_BIN" ]]; then ok "variant.json binaryPath is executable: $V_BIN"
    else fail VARIANT "variant.json binaryPath is not an executable file: $V_BIN"; fi
    V_ORIG=$(_field "$VARIANT" claudeOrig); V_ORIG_VER=$(printf '%s' "$V_ORIG" | _semver)
    if [[ -n "$V_ORIG_VER" && -n "$INSTALLED" && "$V_ORIG_VER" != "$INSTALLED" ]]; then
        warn "variant.json claudeOrig is pinned at $V_ORIG_VER while $INSTALLED is installed — a cc-mirror re-provision (update/create/quick) would install $V_ORIG_VER. cc-update.sh rewrites this pin; a bare cc-mirror never does."
    else
        info "variant.json claudeOrig=${V_ORIG:-<absent>}"
    fi
else
    fail VARIANT "variant.json missing at $VARIANT"
fi

# ── 4. LAUNCHER: the file the launcher execs must exist (the dead-launcher check) ───────
if [[ ! -f "$LAUNCHER" ]]; then
    fail LAUNCHER "launcher missing at $LAUNCHER"
else
    EXEC_LINE=$(grep -E '^[[:space:]]*exec ' "$LAUNCHER" 2>/dev/null | tail -1 || true)
    if [[ -z "$EXEC_LINE" ]]; then
        fail LAUNCHER "no exec line found in $LAUNCHER"
    else
        TARGET=$(_exec_target "$EXEC_LINE")
        if [[ -z "$TARGET" ]]; then fail LAUNCHER "cannot parse the exec target from: $EXEC_LINE"
        elif [[ -f "$TARGET" ]]; then ok "launcher exec target exists: $TARGET"
        else fail LAUNCHER "launcher exec target does not exist: $TARGET (line: $EXEC_LINE) — mclaude cannot start"; fi
        if [[ "$EXEC_LINE" == *"exec node "* ]] && ! command -v node >/dev/null 2>&1; then
            fail LAUNCHER "launcher runs 'exec node …' but node is not on PATH"
        fi
        [[ -n "$TARGET" && -n "$V_BIN" && "$TARGET" != "$V_BIN" ]] && warn "launcher exec target ($TARGET) differs from variant.json binaryPath ($V_BIN)"
    fi
    if grep -q 'update-checker.sh' "$LAUNCHER" 2>/dev/null; then ok "launcher invokes update-checker.sh"
    else warn "launcher does not invoke update-checker.sh — the daily version notice never runs at startup (cc-update.sh wires it on the next update; see cc-update.sh --help)"; fi
fi

# ── 5. SETTINGS: every live env key must be fleet policy (template ∪ overlays ∪ vault) ──
if [[ -f "$LIVE_SETTINGS" ]]; then
    if [[ ! -f "$TEMPLATE" ]]; then
        info "settings template not found at $TEMPLATE — live env keys not checked"
    elif ! command -v python3 >/dev/null 2>&1; then
        info "python3 not available — live env keys not checked"
    else
        POLICY=$(_env_keys "$TEMPLATE")
        for _ov in "$OVERLAY_DIR"/*/settings.json; do [[ -f "$_ov" ]] && POLICY="$POLICY"$'\n'"$(_env_keys "$_ov")"; done
        [[ -f "$VAULT_MANAGE" ]] && POLICY="$POLICY"$'\n'"$(grep -oE "env\['[A-Za-z_]+'\]" "$VAULT_MANAGE" 2>/dev/null | sed "s/env\['\(.*\)'\]/\1/" || true)"
        LEAKED=""
        while IFS= read -r _k; do
            [[ -n "$_k" ]] || continue
            grep -qx "$_k" <<<"$POLICY" || LEAKED="${LEAKED:+$LEAKED,}$_k"
        done <<<"$(_env_keys "$LIVE_SETTINGS")"
        if [[ -n "$LEAKED" ]]; then
            fail SETTINGS "live $LIVE_SETTINGS env carries key(s) the fleet does not declare: $LEAKED — not in $TEMPLATE, not in a machine overlay under $OVERLAY_DIR, not written by vault-manage.sh deploy. Something outside sync.sh wrote them."
        else
            ok "live settings.json env keys are all fleet-declared"
        fi
    fi
fi

# ── 6. Snapshot comparison: DOWNGRADE and UNREQUESTED ───────────────────────────────────
TEAM=$(_bool_field "$VARIANT" teamModeEnabled); TEAM="${TEAM:-unset}"
_names=()
for _d in "$SKILLS_DIR"/*/; do [[ -d "$_d" ]] && _names+=("$(basename "$_d")"); done
SKILLS=""; if ((${#_names[@]})); then SKILLS=$(printf '%s\n' "${_names[@]}" | sort | paste -sd, -); fi
if [[ -f "$SNAPSHOT" ]]; then
    S_VER=$(grep '^version=' "$SNAPSHOT" | head -1 | cut -d= -f2- || true)
    S_TEAM=$(grep '^teamModeEnabled=' "$SNAPSHOT" | head -1 | cut -d= -f2- || true)
    S_SKILLS=$(grep '^skills=' "$SNAPSHOT" | head -1 | cut -d= -f2- || true)
    if [[ -n "$INSTALLED" && -n "$S_VER" ]]; then
        if _ver_lt "$INSTALLED" "$S_VER"; then
            if ((ALLOW_DOWNGRADE)); then warn "installed $INSTALLED is below the last-known-good $S_VER — downgrade explicitly allowed"
            else fail DOWNGRADE "installed $INSTALLED is BELOW the last-known-good snapshot $S_VER ($SNAPSHOT) — something re-provisioned or reset the install"; fi
        elif [[ "$INSTALLED" == "$S_VER" ]]; then ok "installed $INSTALLED equals the snapshot"
        else ok "installed $INSTALLED is above the snapshot $S_VER (upgrade)"; fi
    fi
    if [[ "$TEAM" != "${S_TEAM:-unset}" ]]; then
        _m="variant.json teamModeEnabled changed since the snapshot: ${S_TEAM:-unset} → $TEAM (nothing in the fleet's update path sets this; cc-mirror team-mode provisioning does)"
        if ((ALLOW_UNREQUESTED)); then warn "$_m"; else fail UNREQUESTED "$_m"; fi
    else
        ok "variant.json teamModeEnabled=$TEAM unchanged since the snapshot"
    fi
    ADDED=$(comm -13 <(tr ',' '\n' <<<"$S_SKILLS" | sed '/^$/d' | sort) <(tr ',' '\n' <<<"$SKILLS" | sed '/^$/d' | sort) | paste -sd, - || true)
    REMOVED=$(comm -23 <(tr ',' '\n' <<<"$S_SKILLS" | sed '/^$/d' | sort) <(tr ',' '\n' <<<"$SKILLS" | sed '/^$/d' | sort) | paste -sd, - || true)
    if [[ -n "$ADDED" ]]; then
        _m="skills appeared under $SKILLS_DIR that were not in the snapshot: $ADDED (snapshot had: ${S_SKILLS:-none})"
        if ((ALLOW_UNREQUESTED)); then warn "$_m"; else fail UNREQUESTED "$_m"; fi
    fi
    [[ -n "$REMOVED" ]] && warn "skills recorded in the snapshot are gone: $REMOVED"
    [[ -z "$ADDED" && -z "$REMOVED" ]] && ok "skill set unchanged since the snapshot (${SKILLS:-none})"
else
    info "no snapshot at $SNAPSHOT — baseline run, nothing to compare against"
fi

# ── 7. EXPECT: the caller states what it just installed ─────────────────────────────────
if [[ -n "$EXPECT" ]]; then
    if [[ "$INSTALLED" == "$EXPECT" ]]; then ok "installed $INSTALLED is the expected version"
    else fail EXPECT "expected $EXPECT but the installed version is ${INSTALLED:-UNKNOWN}"; fi
fi

# ── 8. Snapshot write: only a clean run (or --force) may become the baseline ────────────
if ((WRITE)); then
    if [[ -z "$INSTALLED" ]]; then
        warn "snapshot NOT written — no installed version to record"
    elif ((FAILS == 0)) || ((FORCE)); then
        _tag=""; ((FORCE)) && ((FAILS > 0)) && _tag=" [FORCED over $FAILS FAIL line(s)]"
        if mkdir -p "$(dirname "$SNAPSHOT")" 2>/dev/null && printf 'version=%s\nteamModeEnabled=%s\nskills=%s\n' "$INSTALLED" "$TEAM" "$SKILLS" > "$SNAPSHOT"; then
            info "snapshot written: $SNAPSHOT (version=$INSTALLED teamModeEnabled=$TEAM skills=${SKILLS:-none})$_tag"
        else
            warn "snapshot NOT written — cannot write $SNAPSHOT"
        fi
    else
        warn "snapshot NOT written — $FAILS FAIL line(s) above; a failing install must not become the baseline (--force accepts it deliberately)"
    fi
fi

printf 'RESULT: %d FAIL (mirror=%s launcher=%s snapshot=%s)\n' "$FAILS" "$MIRROR" "$LAUNCHER" "$SNAPSHOT"
[[ "$FAILS" -eq 0 ]]
