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

# On-disk size of the resolved model's largest .gguf, in MiB. 0 if it cannot be found —
# callers must treat 0 as "unknown" and skip the check rather than blocking the load.
alm_model_size_mib() {
    # An lms key may carry a quant suffix: `name@q4_k_m`. Honour it — several quants of the
    # same model sit side by side, and matching the base name alone picks the largest (the
    # Q8), over-stating VRAM need and refusing loads that would fit. Observed 2026-08-13.
    local base="${ALM_KEY%%@*}" quant=""
    [[ "$ALM_KEY" == *@* ]] && quant="${ALM_KEY##*@}"
    local roots=("$HOME/.lmstudio/models") r f best=0 sz
    for r in /mnt/c/Users/*/.lmstudio/models; do [[ -d "$r" ]] && roots+=("$r"); done
    for r in "${roots[@]}"; do
        [[ -d "$r" ]] || continue
        while IFS= read -r f; do
            [[ -n "$quant" ]] && ! grep -qiF -- "$quant" <<<"$(basename "$f")" && continue
            sz=$(stat -c %s "$f" 2>/dev/null) || continue
            [[ "$sz" -gt "$best" ]] && best="$sz"
            # -L: a models dir is often a symlink to another disk; without it, find returns
            # nothing and the preflight silently degrades to "size unknown".
        done < <(find -L "$r" -maxdepth 4 -iname '*.gguf' ! -iname 'mmproj*' 2>/dev/null | grep -iF -- "$base" 2>/dev/null)
        [[ "$best" -gt 0 ]] && break
    done
    printf '%s' $(( best / 1048576 ))
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

    # ── VRAM preflight ───────────────────────────────────────────────────────
    # Measured 2026-08-13: with ~8 GB of the 4090 already held by other work, LM Studio
    # loaded an 18.69 GB model "successfully" and then crawled — it had silently spilled
    # into shared system memory over PCIe. The load reports success; only the speed tells
    # you. Refuse up front instead, in plain language.
    if command -v nvidia-smi >/dev/null 2>&1; then
        local free_mib weights_mib
        free_mib=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1)
        weights_mib=$(alm_model_size_mib)
        if [[ "$free_mib" =~ ^[0-9]+$ && "$weights_mib" =~ ^[0-9]+$ && "$weights_mib" -gt 0 ]]; then
            # Weights plus a floor for KV cache and compute buffers.
            local need=$(( weights_mib + 1200 ))
            echo "  vram: ${free_mib} MiB free, model needs ~${need} MiB (weights ${weights_mib} + buffers)"
            if [[ "$free_mib" -lt "$need" ]]; then
                echo "" >&2
                echo "  NOT ENOUGH FREE VRAM — refusing to load." >&2
                echo "  Free ${free_mib} MiB, need ~${need} MiB. LM Studio would appear to load and then" >&2
                echo "  crawl, because it spills to system RAM over PCIe rather than failing." >&2
                echo "" >&2
                echo "  Options: free the GPU (see 'nvidia-smi'), pick a smaller alias," >&2
                echo "  or set AFLEET_VRAM_OVERRIDE=1 to load anyway and accept the slowdown." >&2
                [[ "${AFLEET_VRAM_OVERRIDE:-0}" == "1" ]] || return 1
                echo "  AFLEET_VRAM_OVERRIDE=1 set — loading anyway." >&2
            fi
        fi
    fi

    if ! _alm_lms "$lms" server status 2>/dev/null | grep -qi "running"; then
        echo "  starting LM Studio server on :$ALM_PORT ..."
        _alm_lms "$lms" server start --port "$ALM_PORT" >/dev/null 2>&1 || {
            echo "  could not start the LM Studio server" >&2; return 1; }
    fi

    if _alm_lms "$lms" ps 2>/dev/null | grep -q "$alias"; then
        echo "  model already loaded"
    else
        echo "  loading model (this can take a minute on first load) ..."
        # --parallel 1: LM Studio defaults to 4 concurrent prediction slots. Claude Code is a
        # single session, and every extra slot costs KV cache for throughput we never use.
        # Observed 2026-08-13: gemma4 loaded with PARALLEL 4 by default.
        _alm_lms "$lms" load "$ALM_KEY" --gpu "$ALM_GPU" -c "$ALM_CTX" --parallel 1 \
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
    # The statusline cannot infer a local window: CC reports the alias as the model
    # name and no context_window_size, so statusline-command.sh would fall back to
    # 1,000,000 and render a nearly-full 16k session as 2% used. The pinned number
    # is right here in the conf — pass it through rather than let it be guessed.
    export AFLEET_LOCAL_CTX="$ALM_CTX"
    return 0
}
