#!/usr/bin/env bash
# Anti-lockout check — fast gate for agent-fleet shutdown (CFG-339)
# Verifies no changes will break CC startup. Runs in <2 seconds.
#
# Usage: bash anti-lockout-check.sh [--hooks-dir DIR] [--config-dir DIR] [--claude-dir DIR]
#   Defaults to live deployed paths if no args given.
#
# Exit 0 = PASS (safe to commit/shutdown)
# Exit 1 = FAIL (fix before committing)

set -euo pipefail

# ── Defaults (live deployed paths) ───────────────────────────────────────────

HOOKS_DIR="${HOME}/.claude/hooks"
CONFIG_DIR="${HOME}/.cc-mirror/mclaude/config"
CLAUDE_DIR="${HOME}/.claude"

# ── Argument parsing ─────────────────────────────────────────────────────────

# Fixture mode: any --*-dir override means the caller is a test harness pointing at
# a scratch tree, not a real shutdown gating a real commit. The E2E freshness check
# is scoped to real invocations so it reports on the actual repo, not a fixture.
FIXTURE_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hooks-dir)  HOOKS_DIR="$2"; FIXTURE_MODE=1; shift 2 ;;
        --config-dir) CONFIG_DIR="$2"; FIXTURE_MODE=1; shift 2 ;;
        --claude-dir) CLAUDE_DIR="$2"; FIXTURE_MODE=1; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Check functions ──────────────────────────────────────────────────────────

ERRORS=0

fail() {
    echo "FAIL: $1" >&2
    ERRORS=$((ERRORS + 1))
}

# 1. safe-run.sh must exist (the lockout gateway)
check_safe_run_exists() {
    if [[ ! -f "$HOOKS_DIR/safe-run.sh" ]]; then
        fail "safe-run.sh missing from $HOOKS_DIR"
    fi
}

# 2. Bash syntax check on all hooks (including subdirectories)
check_hook_syntax() {
    local hook
    while IFS= read -r -d '' hook; do
        if ! bash -n "$hook" 2>/dev/null; then
            fail "syntax error in $(basename "$hook")"
        fi
    done < <(find "$HOOKS_DIR" -name '*.sh' -print0 2>/dev/null)
}

# 3. settings.json must be valid JSON
check_settings_json() {
    local settings="$CONFIG_DIR/settings.json"
    [[ -f "$settings" ]] || { fail "settings.json not found"; return; }
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$settings" 2>/dev/null; then
        fail "settings.json is invalid JSON"
    fi
}

# 4. .mcp.json must be valid JSON (if it exists)
check_mcp_json() {
    local mcp="$CONFIG_DIR/.mcp.json"
    [[ -f "$mcp" ]] || return 0
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$mcp" 2>/dev/null; then
        fail ".mcp.json is invalid JSON"
    fi
}

# 5. All hook commands in settings.json must route through safe-run.sh
check_safe_run_routing() {
    local settings="$CONFIG_DIR/settings.json"
    [[ -f "$settings" ]] || return 0
    # Extract every command-type hook from the hooks section (not statusLine, not other
    # top-level). The REAL CC schema is matcher-nested: event → [{matcher, hooks:[{type,
    # command}]}], so we MUST descend group['hooks'][] — reading h.get('command') on the
    # matcher group finds nothing (the Fable-R3/C3 vacuous-PASS bug, 2026-07-05). Defensive:
    # a flat {type,command} entry (no 'hooks' key) is still handled. Every command hook is
    # checked regardless of interpreter prefix (a 'sh ...'/bare-path hook bypasses too).
    local cmds
    cmds=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d.get('hooks', {})
for event, groups in hooks.items():
    if not isinstance(groups, list):
        continue
    for group in groups:
        if not isinstance(group, dict):
            continue
        entries = group.get('hooks', [group])   # nested schema, else treat group as flat
        for h in entries:
            if isinstance(h, dict) and h.get('type') == 'command':
                cmd = h.get('command', '')
                if cmd:
                    print(cmd)
" "$settings" 2>/dev/null) || true
    [[ -z "$cmds" ]] && return 0
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        if [[ "$cmd" != *"safe-run.sh"* ]]; then
            fail "hook bypasses safe-run.sh: $cmd"
        fi
    done <<< "$cmds"
}

# 6. settings.json must have a hooks section (empty = all hooks silently disabled)
check_hooks_section() {
    local settings="$CONFIG_DIR/settings.json"
    [[ -f "$settings" ]] || return 0
    if ! python3 -c "
import json,sys
d = json.load(open(sys.argv[1]))
assert 'hooks' in d and d['hooks'], 'no hooks'
" "$settings" 2>/dev/null; then
        fail "settings.json has no hooks section — all hooks disabled"
    fi
}

# 7. Critical directories must exist
check_critical_dirs() {
    if [[ ! -d "$CLAUDE_DIR/foundation" ]]; then
        fail "foundation directory missing from $CLAUDE_DIR"
    fi
}

# ── CFG-433 A4 slice 5: mesh-lockout tripwires ───────────────────────────────
# Guards the 2026-06-23 lockout that motivated the cutover sentinel. Only fires
# when the machine actually has a cron/leader to check — silent skip elsewhere.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 8. H2: NUC crontab must NOT run the pre-mesh double-writers.
#    cc-refresh-cron.sh or cc-credentials-propagate.sh push in an active
#    (non-commented) crontab line ⇒ fleet-wide lineage death within ~8h.
check_nuc_crontab_hygiene_H2() {
    local ct=""
    if [[ -n "${CC_MESH_ANTILOCKOUT_CRONTAB_FILE:-}" ]]; then
        [[ -f "$CC_MESH_ANTILOCKOUT_CRONTAB_FILE" ]] || return 0
        ct="$(cat "$CC_MESH_ANTILOCKOUT_CRONTAB_FILE")"
    else
        command -v crontab >/dev/null 2>&1 || return 0
        ct="$(crontab -l 2>/dev/null || true)"
    fi
    [[ -z "$ct" ]] && return 0
    # Strip commented lines before matching — a retired-but-commented line is inert.
    local active
    active="$(printf '%s\n' "$ct" | grep -v '^[[:space:]]*#')"
    if printf '%s\n' "$active" | grep -Eq 'cc-refresh-cron\.sh'; then
        fail "H2: NUC crontab still runs cc-refresh-cron.sh — retired by CFG-433 A4 mesh cutover, must be removed (2026-06-23 lockout guard)"
    fi
    if printf '%s\n' "$active" | grep -Eq 'cc-credentials-propagate\.sh[[:space:]]+push'; then
        fail "H2: NUC crontab still runs cc-credentials-propagate.sh push — pre-mesh double-writer, must be removed (would race the mesh leader → lineage death)"
    fi
}

# 9. RUNWAY_OK contract: bash cc-mesh-leader.sh config at the configured TTL
#    MUST emit RUNWAY_OK=1. Catches misconfigured TTL raises at cutover time,
#    not 6h into a botched failover.
check_runway_ok_at_configured_ttl() {
    local leader="${CC_MESH_ANTILOCKOUT_LEADER_BIN:-$SCRIPT_DIR/cc-mesh-leader.sh}"
    [[ -x "$leader" ]] || return 0  # silent skip on machines without the mesh scripts
    local ttl="${CC_MESH_ANTILOCKOUT_TTL:-5400}"
    local cfg
    cfg="$(CC_MESH_TTL="$ttl" bash "$leader" config 2>/dev/null || true)"
    [[ -z "$cfg" ]] && return 0
    local runway
    runway="$(printf '%s\n' "$cfg" | grep -E '^RUNWAY_OK=' | head -1 | cut -d= -f2)"
    if [[ "$runway" != "1" ]]; then
        fail "RUNWAY_OK=$runway at CC_MESH_TTL=$ttl — leader config would refuse to cut over. Lower TTL or raise CC_MESH_TOKEN_RUNWAY_SEC."
    fi
}

# 10. Tier 2 edits must not reach a commit without a recorded E2E run (CFG-586).
#     The Tier 2 rule says E2E is required "before committing", but nothing enforced
#     it — on 2026-09-10 a session disclosed "podman E2E NOT run" and committed
#     anyway, then ran it 20 minutes later in ~90s and it passed. Disclosure had
#     become a substitute for compliance, so the gate lives here, where shutdown
#     already stops.
#     Deliberately NO "podman unavailable" skip: that is Known Faulty Pattern 7,
#     which disables the gate exactly where it is load-bearing. A machine that
#     cannot run E2E must fail loudly and have a human decide.
check_e2e_freshness() {
    local repo marker
    # In fixture mode the repo under test is a scratch tree; run only when a repo is
    # named explicitly (the check's own tests do that) or this is a real invocation.
    [[ "$FIXTURE_MODE" -eq 1 && -z "${ANTILOCKOUT_REPO_DIR:-}" ]] && return 0
    repo="${ANTILOCKOUT_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
    marker="${ANTILOCKOUT_E2E_MARKER:-$HOME/.claude/.last-e2e-run}"
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0

    local changed
    changed="$(git -C "$repo" status --porcelain -- setup/scripts global/hooks setup/config 2>/dev/null || true)"
    [[ -z "$changed" ]] && return 0

    if [[ ! -f "$marker" ]]; then
        fail "Tier 2 paths modified but no E2E run is recorded. Run: bash setup/scripts/e2e-podman.sh"
        return 0
    fi

    local line f stale=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        f="${line:3}"
        [[ -f "$repo/$f" ]] || continue
        if [[ "$repo/$f" -nt "$marker" ]]; then stale="$f"; break; fi
    done <<< "$changed"

    [[ -n "$stale" ]] && \
        fail "Tier 2 file '$stale' is newer than the last recorded E2E run. Run: bash setup/scripts/e2e-podman.sh"
    return 0
}

# 11. Distribute-verb visibility line — already asserted by
#     test_distribute_verb_accepted_by_real_dispatch in test-cc-mesh-leader.sh.
#     No failure path, just surface in the pass output for operator awareness.
DISTRIBUTE_VERB_NOTED=1

# ── Run all checks ───────────────────────────────────────────────────────────

check_safe_run_exists
check_hook_syntax
check_settings_json
check_mcp_json
check_safe_run_routing
check_hooks_section
check_critical_dirs
check_nuc_crontab_hygiene_H2
check_runway_ok_at_configured_ttl
check_e2e_freshness

if [[ $ERRORS -gt 0 ]]; then
    echo "ANTI-LOCKOUT: $ERRORS failure(s) — fix before shutdown" >&2
    exit 1
fi
echo "ANTI-LOCKOUT: PASS"
[[ "${DISTRIBUTE_VERB_NOTED:-0}" = "1" ]] && \
    echo "ANTI-LOCKOUT: NOTE distribute-verb contract asserted by test-cc-mesh-leader.sh (test_distribute_verb_accepted_by_real_dispatch)"
exit 0
