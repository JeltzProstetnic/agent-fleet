#!/usr/bin/env bash
# afleet-wrapper.sh — Safety shell for afleet launcher (CFG-256)
# COPIED (not symlinked) to ~/.local/bin/afleet by sync.sh deploy.
# Validates afleet.sh + afleet-lib.sh syntax before exec.
# Falls back to direct claude if validation fails.
# Self-contained: no sourcing, no external deps beyond bash.

_HOME="${AFLEET_WRAPPER_HOME:-$HOME}"

# ── Find afleet.sh in repo ───────────────────────────────────────────────────
_AFLEET=""
_AFLEET_LIB=""
for _d in "$_HOME/cfg-agent-fleet" "$_HOME/agent-fleet"; do
    if [[ -f "$_d/setup/scripts/afleet.sh" ]]; then
        _AFLEET="$_d/setup/scripts/afleet.sh"
        _AFLEET_LIB="$_d/setup/scripts/afleet-lib.sh"
        break
    fi
done

# ── Fallback launch ─────────────────────────────────────────────────────────
_fallback() {
    echo "" >&2
    echo "  !! AFLEET DEGRADED LAUNCH — $1" >&2
    echo "  Launching Claude Code directly (no sync, no project detection)." >&2
    echo "" >&2
    local _fb="${AFLEET_WRAPPER_FALLBACK:-}"
    if [[ -n "$_fb" ]]; then
        exec $_fb
    fi
    for _c in "$_HOME/.local/bin/mclaude" "$_HOME/.cc-mirror/bin/mclaude.cmd" "$(command -v mclaude 2>/dev/null)" "$(command -v claude 2>/dev/null)"; do
        [[ -n "$_c" && -x "$_c" ]] && exec "$_c"
    done
    echo "  FATAL: Neither mclaude nor claude found." >&2
    exit 1
}

# ── Validate ─────────────────────────────────────────────────────────────────
[[ -z "$_AFLEET" ]] && _fallback "afleet.sh not found in any repo"
[[ ! -f "$_AFLEET_LIB" ]] && _fallback "afleet-lib.sh missing: $_AFLEET_LIB"
bash -n "$_AFLEET" 2>/dev/null || _fallback "afleet.sh has syntax errors"
bash -n "$_AFLEET_LIB" 2>/dev/null || _fallback "afleet-lib.sh has syntax errors"

# ── Launch ───────────────────────────────────────────────────────────────────
exec bash "$_AFLEET" "$@"
