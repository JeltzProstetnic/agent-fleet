#!/usr/bin/env bash
# lib-leak-gate.sh — the ONE leak gate every egress path calls (CFG-626).
#
# Egress = anything that pushes fleet content outward: template-push.sh (the
# public template), filtered-push.sh (a project's public mirror), mobile-deploy.sh
# and config-auto-sync.sh Phase 4 (the mobile repo). Each used to decide for
# itself whether to scan anything — template-push.sh had a grep of its own, the
# other three had none — and mobile-deploy's silence lasted five weeks. One
# function, called by all of them, so test-egress-leak-gate.sh can assert the
# call and the non-empty vocabulary structurally AND behaviourally.
#
# Contract (sourced, never executed; no set -e here — the caller's mode applies):
#
#   check_leaks <patterns> <path>...
#       grep -E over files; recursive for directories, .git excluded, binaries
#       skipped. Prints every hit as path:line:text on stdout.
#       Returns 0 clean, 1 at least one hit, 2 REFUSED: the pattern list is
#       empty or does not compile, a path cannot be read, or a given path
#       does not exist. 2 is fail-closed and the caller must publish NOTHING —
#       an empty list is not "nothing to look for" (CFG-639), and a path that
#       was not scanned is not a clean path.
#   leak_gate_hit_files
#       stdin = check_leaks output → unique paths, one per line.
#   leak_gate_conf_value <conf> <key>
#       value of `key=value` in a conf, trimmed with parameter expansion (never
#       xargs — it eats backslashes, CFG-606); empty when key or conf is absent.
#
# Vocabularies — WHICH list a caller passes depends on the destination:
#   - the PUBLIC template gets template-push.conf's personal_patterns;
#   - every destination, private repos included, gets LEAK_GATE_SECRET_PATTERNS:
#     credential VALUES (token prefixes with long random bodies, private-key
#     headers). Deliberately narrower than the SessionEnd hook's staged-diff
#     scan (a password or secret LABEL in prose is not a credential): the callers
#     here HOLD or REFUSE on a hit, and a false positive would block a whole
#     push on a documentation line.

# Token prefixes: Anthropic, OpenAI (incl. project-scoped sk-proj-), AWS, Google,
# GitHub (ghp/gho/ghu/ghs/ghr, fine-grained github_pat_), GitLab, npm, Slack; PEM
# private keys; and a key/token/secret name in either case followed by a long
# base64-ish value.
LEAK_GATE_SECRET_PATTERNS='sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIzaSy[A-Za-z0-9_-]{33}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36,}|xox[bp]-[A-Za-z0-9-]{10,}|-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt])[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9+/]{40,}={0,2}'

check_leaks() {
    local patterns="${1-}"
    shift || true
    if [[ -z "$patterns" ]]; then
        echo "check_leaks: EMPTY pattern list — refusing to scan (fail closed)" >&2
        return 2
    fi
    # grep -E on /dev/null: 1 = valid regex with no match, 2 = does not compile.
    local rc=0
    grep -E -e "$patterns" /dev/null >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ge 2 ]]; then
        echo "check_leaks: pattern list does not compile as a grep -E regex — refusing to scan (fail closed)" >&2
        return 2
    fi
    local p hits found=0 err=0
    for p in "$@"; do
        rc=0
        if [[ -d "$p" ]]; then
            hits=$(grep -rHnI -E --exclude-dir=.git -e "$patterns" -- "$p" 2>/dev/null) || rc=$?
        elif [[ -f "$p" ]]; then
            hits=$(grep -HnI -E -e "$patterns" -- "$p" 2>/dev/null) || rc=$?
        else
            # Asked to scan it and cannot: the caller's list and the bytes it
            # is about to publish disagree (a C-quoted name, a removed
            # snapshot). Unscanned is not clean.
            echo "check_leaks: cannot scan '$p' (missing, or not a file or directory) — refusing to pass (fail closed)" >&2
            err=1
            continue
        fi
        case "$rc" in
            0) found=1; printf '%s\n' "$hits" ;;
            1) ;;
            *) err=1 ;;
        esac
    done
    if [[ "$err" -eq 1 ]]; then
        echo "check_leaks: grep failed on at least one path — refusing to pass (fail closed)" >&2
        return 2
    fi
    [[ "$found" -eq 0 ]] || return 1
    return 0
}

leak_gate_hit_files() {
    cut -d: -f1 | awk 'NF' | sort -u
}

leak_gate_conf_value() {
    local conf="$1" want="$2" key value
    [[ -f "$conf" ]] || return 0
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" == "$want" ]] || continue
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        printf '%s' "$value"
        return 0
    done < "$conf"
    return 0
}
