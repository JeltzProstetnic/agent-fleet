#!/usr/bin/env bash
# afleet-local-model.sh — LM Studio driver for `af <project> <alias>` (CFG-506)
#
# Sourced by afleet.sh. Lives in its own file because afleet.sh is already past the
# 600-line split threshold.
#
# WHY THIS IS SHORT: LM Studio >= 0.4.1 serves a NATIVE Anthropic `POST /v1/messages`
# endpoint, so Claude Code talks to it directly — no proxy, no LiteLLM, no
# claude-code-router. Three env vars and `--model`.
#
# Public API:
#   alm_resolve <alias>    → sets ALM_KEY ALM_CTX ALM_GPU ALM_TTL ALM_PROFILE
#   alm_prepare <alias>    → resolve, start server, load model, health-check, export env
#   alm_list_aliases       → print known aliases (for error messages)

ALM_CONF="${ALM_CONF:-$HOME/.claude/local-models.conf}"
ALM_PORT="${ALM_PORT:-1234}"
ALM_BASE="http://localhost:${ALM_PORT}"

_alm_conf_file() {
    for c in "$ALM_CONF" "$CONFIG_REPO/setup/config/local-models.conf"; do
        [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

alm_list_aliases() {
    local f; f=$(_alm_conf_file) || return 1
    grep -vE '^\s*(#|$)' "$f" | awk -F'|' '{gsub(/ /,"",$1); print $1}' | paste -sd' ' -
}

# alm_resolve <alias> — parse the conf row. Returns 1 if the alias is unknown.
alm_resolve() {
    local alias="$1" f row
    f=$(_alm_conf_file) || { echo "  local-models.conf not found" >&2; return 1; }
    # Compare a COPY of field 1 — assigning to $1 makes awk rebuild $0 using OFS (a space),
    # which destroys the pipe delimiters and breaks every downstream field parse.
    row=$(grep -vE '^\s*(#|$)' "$f" | awk -F'|' -v a="$alias" '{k=$1; gsub(/ /,"",k); if (k==a) print}' | head -1)
    [[ -n "$row" ]] || return 1
    ALM_KEY=$(awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' <<<"$row")
    ALM_CTX=$(awk -F'|' '{gsub(/ /,"",$3); print $3}' <<<"$row")
    ALM_GPU=$(awk -F'|' '{gsub(/ /,"",$4); print $4}' <<<"$row")
    ALM_TTL=$(awk -F'|' '{gsub(/ /,"",$5); print $5}' <<<"$row")
    ALM_PROFILE=$(awk -F'|' '{gsub(/ /,"",$6); print $6}' <<<"$row")
    [[ -n "$ALM_KEY" && -n "$ALM_CTX" ]] || return 1
    return 0
}

# Locate the lms binary. On WSL this is the Windows exe under the Windows user profile.
alm_find_lms() {
    [[ -n "${AFLEET_LMS_BIN:-}" && -x "$AFLEET_LMS_BIN" ]] && { printf '%s' "$AFLEET_LMS_BIN"; return 0; }
    local c
    for c in "$HOME/.lmstudio/bin/lms" "$HOME/.cache/lm-studio/bin/lms"; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    # WSL: Windows-side install. Enumerate /mnt/c/Users/* rather than hardcoding a name.
    local u
    for u in /mnt/c/Users/*/.lmstudio/bin/lms.exe; do
        [[ -f "$u" ]] && { printf '%s' "$u"; return 0; }
    done
    return 1
}

# WSL TRAP: a Windows exe launched while the bash cwd is a WSL path lands on the
# \\wsl.localhost\... UNC path and the unc-path-guard bites. Always run from /mnt.
_alm_lms() {
    local bin="$1"; shift
    if [[ "$bin" == *.exe ]]; then ( cd /mnt/c 2>/dev/null && "$bin" "$@" )
    else "$bin" "$@"; fi
}

# alm_prepare <alias> — the whole sequence. Non-zero on any failure; the caller MUST abort.
# There is deliberately NO fallback to cloud Opus: silently spending Opus tokens when the
# user asked for a local model is exactly the surprise this feature exists to prevent.
alm_prepare() {
    local alias="$1"

    if ! alm_resolve "$alias"; then
        echo "" >&2
        echo "  Unknown model alias: '$alias'" >&2
        echo "  Known aliases: $(alm_list_aliases 2>/dev/null || echo '(conf unreadable)')" >&2
        echo "  Add one in setup/config/local-models.conf" >&2
        return 1
    fi

    local lms; lms=$(alm_find_lms) || {
        echo "  LM Studio CLI (lms) not found — install LM Studio, or set AFLEET_LMS_BIN." >&2
        echo "  Looked in ~/.lmstudio/bin/ and /mnt/c/Users/*/.lmstudio/bin/lms.exe" >&2
        return 1
    }

    echo "  local model: $alias → $ALM_KEY (ctx $ALM_CTX, gpu $ALM_GPU, profile $ALM_PROFILE)"

    if ! _alm_lms "$lms" server status 2>/dev/null | grep -qi "running"; then
        echo "  starting LM Studio server on :$ALM_PORT ..."
        _alm_lms "$lms" server start --port "$ALM_PORT" >/dev/null 2>&1 || {
            echo "  could not start the LM Studio server" >&2; return 1; }
    fi

    if _alm_lms "$lms" ps 2>/dev/null | grep -q "$alias"; then
        echo "  model already loaded"
    else
        echo "  loading model (this can take a minute on first load) ..."
        _alm_lms "$lms" load "$ALM_KEY" --gpu "$ALM_GPU" -c "$ALM_CTX" \
                 --ttl "$ALM_TTL" --identifier "$alias" -y >/dev/null 2>&1 || {
            echo "  model load failed — check: lms load $ALM_KEY --gpu $ALM_GPU -c $ALM_CTX" >&2
            return 1; }
    fi

    # Health check against the real endpoint. If this fails the model is not usable and we
    # must NOT hand the session to Claude Code pointing at a dead base URL.
    local models; models=$(curl -sf -m 10 "$ALM_BASE/v1/models" 2>/dev/null)
    if [[ -z "$models" ]]; then
        echo "  LM Studio is not answering on $ALM_BASE/v1/models" >&2
        echo "  On WSL this is usually Windows-side reachability — check the server is up." >&2
        return 1
    fi
    grep -q "$alias" <<<"$models" || echo "  ! '$alias' not listed by the server; continuing on the loaded model"

    export ANTHROPIC_BASE_URL="$ALM_BASE"
    export ANTHROPIC_AUTH_TOKEN="${LM_API_TOKEN:-lmstudio}"
    export CLAUDE_CODE_ATTRIBUTION_HEADER=0
    export AFLEET_LOCAL_MODEL="$alias"
    export AFLEET_LOCAL_MODEL_KEY="$ALM_KEY"
    export AFLEET_LOCAL_PROFILE="$ALM_PROFILE"
    return 0
}
