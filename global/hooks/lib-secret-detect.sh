#!/usr/bin/env bash
# lib-secret-detect.sh — the fleet's credential detectors, shared by every commit path
# (CFG-892). Sourced by secret-commit-guard.sh (PreToolUse: the commits Claude's Bash
# tool makes) and by global/hooks/git/pre-push (every push, whoever made the commits).
#
#   SHAPE — provider token formats (ghp_…, sk-ant-…, AKIA…, PEM headers), plus a keyword
#           assignment (password/passphrase/secret/private_key = …) judged on its VALUE
#           (CFG-890). grep only, so it runs on every machine.
#   VALUE — salted SHA-256 fingerprints of the fleet's OWN secrets. Three of the four
#           CFG-608 leaks were human-memorable strings written as prose ("the passphrase
#           is X", a table cell, a quoted transcript); those have no shape, only a value
#           comparison finds them. Fingerprints are stored, never values, so the data
#           file is not itself a secret. Needs python3; without it this detector is off,
#           and secret_value_status says so.
#
# Contract:
#   printf '%s' "$added_lines" | secret_detect <repo-root>
#       prints `shape`, `value`, `shape+value` or nothing and returns 0 either way — the
#       verdict is the output. Lines carrying SECRET_ALLOW_MARK are dropped first.
#   secret_value_status <repo-root>
#       prints `armed`, `unconfigured` (no fingerprint files) or `no-python`.
#
# The behaviour is exactly what secret-commit-guard.sh did inline before the move
# (CFG-652/653/662/667/869/890); setup/tests/test-secret-commit-guard.sh pins it.

[[ "${_LIB_SECRET_DETECT_LOADED:-}" == "true" ]] && return 0
_LIB_SECRET_DETECT_LOADED="true"

# Documentation about secret scanning necessarily contains secret-shaped examples —
# the guards' own source, their tests, and the backlog entry that describes them all
# tripped the first real run. A path exemption would be a bypass in disguise and would
# grow; a per-line marker is narrow, visible in the diff, and forces whoever adds it to
# make the claim explicitly. Same shape as git-sweep-guard.sh, where naming a pathspec
# always works.
SECRET_ALLOW_MARK='pragma: allowlist secret'

# AKIA is bounded: an AWS key id is a standalone 20-char token, while a base64 run (a data
# URI, a certificate body) can contain AKIA + 16 [0-9A-Z] mid-string and is not one (CFG-662).
SECRET_PATTERNS='sk-ant-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9]{20,}|(^|[^A-Za-z0-9+/])AKIA[0-9A-Z]{16}($|[^A-Za-z0-9+/])|AIzaSy[A-Za-z0-9_-]{33}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|xoxb-[A-Za-z0-9-]+|xoxp-[A-Za-z0-9-]+|-----BEGIN RSA|-----BEGIN PRIVATE KEY|-----BEGIN OPENSSH PRIVATE KEY|(key|token|secret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/]{40,}={0,2}'  # pragma: allowlist secret

# A keyword assignment (password, passphrase, secret or private_key, then : or =) is
# judged on its VALUE (CFG-890). The key may be JSON-quoted — "password": … — which
# the old pattern never matched, so a real credential in a .json went through. The
# value is exempt only when it is shaped like an ALL_CAPS placeholder, e.g.
# CHANGE_ME_PASSWORD or YOUR_PASSWORD_HERE: a capital, then capitals and underscores
# with at most two digits, six chars or more, optionally quoted, optionally followed
# by closing punctuation. A lowercase letter, a symbol or a third digit makes it a
# value, and it blocks. Each assignment is judged alone: never the whole line (a
# placeholder beside a real value does not cover it) and never the filename (a
# .example name proves nothing). ERE has no lookahead, so the value is extracted
# with -o and tested on its own.
SECRET_KEY_PREFIX='(password|passphrase|secret|private_key)"?[[:space:]]*[:=][[:space:]]*'  # pragma: allowlist secret
SECRET_PLACEHOLDER='^"?[A-Z][A-Z0-9_]{5,}"?[]}),;]*$'

# Candidate tokens: anything that could be a credential. Splitting on whitespace
# alone misses a value inside quotes, a table cell or a sentence ending in a period,
# which is exactly how these leaked. Exit 0 = a token matched a fingerprint.
read -r -d '' _SECRET_FP_PY <<'PY' || true
import hashlib, re, sys
try:
    salt = open(sys.argv[1], "rb").read().strip().decode("utf-8", "replace")
    want = {l.strip() for l in open(sys.argv[2]) if l.strip()}
except OSError:
    sys.exit(1)                      # unreadable -> degrade, never hard-fail
if not want:
    sys.exit(1)
text = sys.stdin.read()
for tok in set(re.split(r"[\s`\"'<>(),;|]+", text)):
    tok = tok.strip(".:!?*_[]{}")
    if len(tok) < 6:
        continue
    if hashlib.sha256((salt + tok).encode()).hexdigest() in want:
        sys.exit(0)                  # matched
sys.exit(1)
PY

# Salt and fingerprints are gitignored and local-only. An unsalted hash of a
# low-entropy secret is brute-forceable, which is why the salt is mandatory:
# without it the fingerprint file would become the next version of the bug it
# prevents. Both layouts (CFG-869): secrets/ at the repo root (the private config
# repo) or setup/secrets/ (a template clone). Root wins when both exist; the
# CC_SECRET_FINGERPRINTS / CC_SECRET_SALT env overrides win over both — the fleet
# exports them from settings.json so every repo value-matches (CFG-667).
# Outside Claude Code (MG's own terminal, cron, a plain script) the env overrides are
# absent and most repos carry no secrets/ dir, so the value detector would silently go
# unarmed for exactly the pushes the pre-push scan exists for (CFG-892). Fallback when
# the repo has no fingerprint pair of its own: the fleet config repo — $CONFIG_REPO,
# else ~/cfg-agent-fleet (private), else ~/agent-fleet (template clone), both layouts.
_secret_fp_paths() {  # <repo-root> → sets _SECRET_FP_FILE and _SECRET_SALT_FILE
    local root="$1" dir="$1/secrets" c
    [ -d "$dir" ] || { [ -d "$root/setup/secrets" ] && dir="$root/setup/secrets"; }
    if [ -z "${CC_SECRET_FINGERPRINTS:-}" ] && ! [ -s "$dir/.secret-fingerprints" ]; then
        for c in "${CONFIG_REPO:+$CONFIG_REPO/secrets}" "${CONFIG_REPO:+$CONFIG_REPO/setup/secrets}" \
                 "$HOME/cfg-agent-fleet/secrets" "$HOME/agent-fleet/setup/secrets"; do
            [ -n "$c" ] && [ -s "$c/.secret-fingerprints" ] && [ -s "$c/.fingerprint-salt" ] && { dir="$c"; break; }
        done
    fi
    _SECRET_FP_FILE="${CC_SECRET_FINGERPRINTS:-$dir/.secret-fingerprints}"
    _SECRET_SALT_FILE="${CC_SECRET_SALT:-$dir/.fingerprint-salt}"
}

secret_value_status() {  # <repo-root>
    _secret_fp_paths "$1"
    if [ -s "$_SECRET_FP_FILE" ] && [ -s "$_SECRET_SALT_FILE" ]; then
        if python3 -c 'import hashlib, re, sys' >/dev/null 2>&1; then echo armed; else echo no-python; fi
    else
        echo unconfigured
    fi
}

secret_detect() {  # <repo-root>; added lines on stdin
    local root="$1" added hits="" values
    added=$(cat)
    added=$(printf '%s\n' "$added" | grep -vF "$SECRET_ALLOW_MARK" || true)
    [ -n "$added" ] || return 0

    # ── Detector 1: shape ─────────────────────────────────────────────────────
    if printf '%s' "$added" | grep -Eq "$SECRET_PATTERNS" 2>/dev/null; then
        hits="shape"
    fi
    if [ -z "$hits" ]; then
        values=$(printf '%s' "$added" | grep -oE "${SECRET_KEY_PREFIX}[^[:space:]]{6,}" 2>/dev/null \
                 | sed -E "s/^${SECRET_KEY_PREFIX}//")
        if [ -n "$values" ] && { printf '%s\n' "$values" | grep -Evq "$SECRET_PLACEHOLDER" \
                                || printf '%s\n' "$values" | grep -Eq '([0-9][^0-9]*){3}'; }; then
            hits="shape"
        fi
    fi

    # ── Detector 2: value fingerprints ────────────────────────────────────────
    _secret_fp_paths "$root"
    if [ -s "$_SECRET_FP_FILE" ] && [ -s "$_SECRET_SALT_FILE" ] && command -v python3 &>/dev/null; then
        if printf '%s' "$added" | python3 -c "$_SECRET_FP_PY" "$_SECRET_SALT_FILE" "$_SECRET_FP_FILE" 2>/dev/null; then
            hits="${hits:+$hits+}value"
        fi
    fi

    [ -n "$hits" ] && printf '%s\n' "$hits"
    return 0
}
