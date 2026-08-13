#!/usr/bin/env bash
# afleet-model-menu.sh — model-selection submenu for the agent fleet launcher (CFG-510)
#
# Lists cloud Opus (the default) plus every alias in local-models.conf, and returns
# the alias the user picked. Sourced LAZILY by afleet.sh's run_model_picker — never
# at boot. That is deliberate: a fault in this file must cost the user a submenu,
# not their launcher.
#
# Depends on afleet-lib.sh for the colour vars, _hline and _pw, and optionally on
# afleet-local-model.sh for on-disk model detection.
#
# Public API:
#   build_model_rows [conf]        → label|alias|name|ctx|profile|status  (pure)
#   render_model_menu              → formatted table, rows on stdin
#   resolve_model_selection <sel>  → alias for a selection, rows on stdin

# Pretty context: 32768 → 32k, 262144 → 256k. Non-numeric passes through.
_format_ctx() {
    local c="$1"
    [[ "$c" =~ ^[0-9]+$ ]] || { printf '%s' "$c"; return 0; }
    if (( c % 1024 == 0 )); then printf '%dk' $(( c / 1024 )); else printf '%s' "$c"; fi
}

# Readable name from an lms key: drop any publisher prefix and the @quant suffix.
_model_display_name() {
    local k="${1%%@*}"
    printf '%s' "${k##*/}"
}

# ready | missing | unknown — is the GGUF actually on disk?
# alm_model_size_mib lives in afleet-local-model.sh and may not be sourced. When it
# is absent the answer is "unknown", never "missing": a menu that claims a model is
# not downloaded while it sits on disk is worse than one that says nothing at all.
_model_disk_status() {
    declare -F alm_model_size_mib >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    local _prev="${ALM_KEY:-}" mib
    ALM_KEY="$1"
    mib=$(alm_model_size_mib 2>/dev/null)
    ALM_KEY="$_prev"
    if [[ "$mib" =~ ^[0-9]+$ && "$mib" -gt 0 ]]; then printf 'ready'; else printf 'missing'; fi
}

# _model_why <alias> — one line on why you would pick this model, so the choice can
# be made without opening the conf or the docs.
#
# Keyed by alias, and deliberately NOT a second model list: alias, context, profile
# and on-disk state all still come from local-models.conf. An alias with no entry
# here just gets no description, so adding a conf row can never break the menu.
_model_why() {
    case "$1" in
        coder)  printf 'MoE, 3B active/token — fastest generation, agentic tools' ;;
        qwen14) printf 'dense — most context headroom (~83k measured)' ;;
        qwen36) printf 'Gated DeltaNet — cheapest KV/token, 262k native' ;;
        gemma4) printf 'biggest weights, tightest context' ;;
        coder14) printf 'dense coder, small footprint — the one that fits a BUSY GPU' ;;
        ask)    printf '~297k reachable — reads and reports, cannot write' ;;
        *)      printf '' ;;
    esac
}

# build_model_rows [conf] — pure row builder. Reads a conf file, writes lines.
# Output: label|alias|name|ctx|profile|status|why
# Row 0 is always cloud Opus — the default, and what an empty selection means.
build_model_rows() {
    local conf="${1:-}" c
    if [[ -z "$conf" ]] && declare -F _alm_conf_file >/dev/null 2>&1; then
        conf=$(_alm_conf_file 2>/dev/null) || conf=""
    fi
    if [[ -z "$conf" ]]; then
        for c in "${ALM_CONF:-}" "${CONFIG_REPO:-}/setup/config/local-models.conf"; do
            [[ -n "$c" && -f "$c" ]] && { conf="$c"; break; }
        done
    fi

    printf '0||Opus (cloud)|—|cloud|cloud|the normal session — full fleet profile, all tools\n'
    [[ -n "$conf" && -f "$conf" ]] || return 0

    local n=0 alias key ctx gpu ttl profile
    while IFS='|' read -r alias key ctx gpu ttl profile; do
        alias="${alias// /}"
        [[ -z "$alias" || "$alias" == \#* ]] && continue
        key="${key// /}"; ctx="${ctx// /}"; profile="${profile// /}"
        [[ -z "$key" || -z "$ctx" ]] && continue
        n=$((n + 1))
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$n" "$alias" \
            "$(_model_display_name "$key")" "$(_format_ctx "$ctx")" \
            "${profile:-lean}" "$(_model_disk_status "$key")" "$(_model_why "$alias")"
    done < <(grep -vE '^\s*(#|$)' "$conf" 2>/dev/null)
}

# render_model_menu — input: build_model_rows output on stdin.
render_model_menu() {
    local -a lbl=() als=() nam=() ctxs=() prf=() sts=() whys=()
    local l a n c p s w i=0
    while IFS='|' read -r l a n c p s w; do
        [[ -z "$l" ]] && continue
        lbl+=("$l"); als+=("$a"); nam+=("$n"); ctxs+=("$c")
        prf+=("$p"); sts+=("$s"); whys+=("$w")
        i=$((i + 1))
    done
    local total=$i
    local col_name=30 col_ctx=5 col_prof=11 col_sts=18
    _RP_inner_width=$((14 + col_name + col_ctx + col_prof + col_sts))

    local has_readonly=0
    printf '  %bMODEL%b\n' "$C_BCYN" "$C_RST"
    _hline "─" "┌" "┐"
    for ((i=0; i<total; i++)); do
        local name="${nam[$i]}" prof="${prf[$i]}" status_txt
        local prof_color="$C_DIM" lbl_color="$C_BWHT"
        case "${sts[$i]}" in
            cloud)   status_txt="default" ;;
            ready)   status_txt="on disk" ;;
            missing) status_txt="— not downloaded" ;;
            *)       status_txt="(size unknown)" ;;
        esac
        # The read-only profile is a SAFETY profile — Write/Edit/Bash are DENIED in
        # settings, not merely discouraged. It must not read as just another row.
        if [[ "$prof" == "readonly" ]]; then
            prof_color="$C_BRED"
            prof="⚠ readonly"
            has_readonly=1
        fi
        [[ "${lbl[$i]}" == "0" ]] && lbl_color="$C_BYEL"
        [[ ${#name} -gt $((col_name - 1)) ]] && name="${name:0:$((col_name - 2))}…"
        [[ ${#status_txt} -gt $col_sts ]] && status_txt="${status_txt:0:$((col_sts - 1))}…"

        printf '%b│%b  %b%2s%b  %-*s  %-*s  %b%-*s%b  %b%-*s%b  %b│%b\n' \
            "$C_DIM" "$C_RST" \
            "$lbl_color" "${lbl[$i]}" "$C_RST" \
            "$(_pw "$col_name" "$name")" "$name" \
            "$(_pw "$col_ctx" "${ctxs[$i]}")" "${ctxs[$i]}" \
            "$prof_color" "$(_pw "$col_prof" "$prof")" "$prof" "$C_RST" \
            "$C_DIM" "$(_pw "$col_sts" "$status_txt")" "$status_txt" "$C_RST" \
            "$C_DIM" "$C_RST"

        # Second line: the alias you would type at the CLI, plus why you'd pick this
        # model. Without it the menu tells you a model exists but not what it is for.
        local sub="${als[$i]}" why="${whys[$i]}"
        if [[ -z "$sub" ]]; then sub="$why"
        elif [[ -n "$why" ]]; then sub="$sub · $why"; fi
        if [[ -n "$sub" ]]; then
            local budget=$((_RP_inner_width - 8))
            [[ ${#sub} -gt $budget ]] && sub="${sub:0:$((budget - 1))}…"
            printf '%b│%b      %b%-*s%b  %b│%b\n' \
                "$C_DIM" "$C_RST" \
                "$C_DIM" "$(_pw "$budget" "$sub")" "$sub" "$C_RST" \
                "$C_DIM" "$C_RST"
        fi

        # Blank line after the cloud default separates it from the local block.
        [[ "${lbl[$i]}" == "0" && $total -gt 1 ]] && \
            printf '%b│%*s│%b\n' "$C_DIM" "$_RP_inner_width" "" "$C_RST"
    done
    _hline "─" "└" "┘"

    if [[ $has_readonly -eq 1 ]]; then
        printf '\n  %b⚠ readonly%b %b= safety profile: Write, Edit and Bash are DENIED in settings.%b\n' \
            "$C_BRED" "$C_RST" "$C_DIM" "$C_RST"
    fi
    printf '\n  %b[#]%b local model  %b[0/Enter]%b Opus (cloud)  %b[q]%b quit\n' \
        "$C_BOLD" "$C_RST" "$C_BOLD" "$C_RST" "$C_BOLD" "$C_RST"
}

# resolve_model_selection <sel> — input: build_model_rows output on stdin.
# Output: the alias to launch. EMPTY for the cloud row, which is NOT an error —
# returns 1 only when nothing matched, so the caller can re-prompt.
resolve_model_selection() {
    local sel="$1" l a n c p s w
    while IFS='|' read -r l a n c p s w; do
        [[ -z "$l" ]] && continue
        if [[ "$l" == "$sel" ]] || [[ -n "$a" && "$a" == "$sel" ]]; then
            printf '%s' "$a"
            return 0
        fi
    done
    return 1
}
