#!/usr/bin/env bash
# PreToolUse hook (CFG-652/653): scan the STAGED DIFF for credentials on every
# `git commit`, whoever issues it.
#
# Why this exists, measured in the lrn audit of 2026-09-21: a secret scan
# already existed, inside config-auto-sync.sh's own commit path. That path
# carried 213 of this repo's 2,583 commits, so ~92% of commits — including all
# four known credential leaks — were never scanned. The guard was bound to the
# SessionEnd event instead of to the commit event. This one is bound to the
# commit, so an ordinary `git commit` typed in a Bash call is covered.
#
# Two detectors, because the old one could only have caught half the problem:
#   SHAPE — provider token formats (ghp_…, sk-ant-…, AKIA…, PEM headers).
#   VALUE — salted SHA-256 fingerprints of the fleet's OWN secrets. Three of
#           the four leaks were human-memorable strings written as prose ("the
#           passphrase is X", a table cell, a quoted transcript). Those have no
#           shape; only a value comparison finds them. Fingerprints are stored,
#           never values, so this file's own data is not a secret.
#
# It reads the staged diff and NOTHING ELSE. CFG-621 is a live defect where
# vault-read-guard.sh blocks ordinary commits because the English word "more"
# appears in an -m body; a guard that false-blocks trains the bypass (CFG-513).
# The commit message is never examined here.
#
# Exit 2 = block with message. Exit 0 = allow.

INPUT=$(cat)

# Bash tool only
if [[ "$INPUT" != *'"tool_name":"Bash"'* && "$INPUT" != *'"tool_name": "Bash"'* ]]; then
    exit 0
fi

CMD=""
if command -v jq &>/dev/null; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
    CMD=$(echo "$INPUT" | grep -oE '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
          | sed 's/.*"command"[^"]*"\([^"]*\)"/\1/')
fi
[ -z "$CMD" ] && exit 0

# Cheap reject before any git work.
[[ "$CMD" == *"git "*"commit"* ]] || exit 0

# ── Resolve which repo the commit applies to ──────────────────────────────────
# Walk each clause so `git -C <dir> commit` targets the right tree. Only a real
# `commit` subcommand counts; `git log --grep commit` must not trigger this.
GIT_C_DIR=""
IS_COMMIT=0
while IFS= read -r clause; do
    # shellcheck disable=SC2086
    set -- $clause
    [ "${1:-}" = "git" ] || continue
    shift
    local_c=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -C) local_c="${2:-}"; shift 2 ;;
            -c) shift 2 ;;
            --no-pager|--no-replace-objects|--bare) shift ;;
            *) break ;;
        esac
    done
    if [ "${1:-}" = "commit" ]; then
        IS_COMMIT=1; GIT_C_DIR="$local_c"; break
    fi
done < <(printf '%s\n' "$CMD" | tr '\n;|' '\n\n\n' | sed 's/&&/\n/g' | sed 's/^[[:space:]]*//')

[ "$IS_COMMIT" -eq 1 ] || exit 0

TARGET_DIR="${GIT_C_DIR:-$PWD}"
[ -d "$TARGET_DIR" ] || exit 0
ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0

# Added lines only. --no-color because this fleet sets color.diff=always, which
# makes every `^+` match fail silently (a documented WSL trap).
ADDED=$(git -C "$ROOT" diff --cached --no-color 2>/dev/null | grep '^+' | grep -v '^+++' || true)

# Documentation about secret scanning necessarily contains secret-shaped
# examples — this guard's own source, its tests, and the backlog entry that
# describes it all tripped it on the first real run. A path exemption would be
# a bypass in disguise and would grow; a per-line marker is narrow, visible in
# the diff, and forces whoever adds it to make the claim explicitly. Same shape
# as git-sweep-guard.sh, where naming a pathspec always works.
ALLOW_MARK='pragma: allowlist secret'
ADDED=$(printf '%s\n' "$ADDED" | grep -vF "$ALLOW_MARK" || true)
[ -n "$ADDED" ] || exit 0

HITS=""

# ── Detector 1: shape ─────────────────────────────────────────────────────────
SECRET_PATTERNS='sk-ant-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIzaSy[A-Za-z0-9_-]{33}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|xoxb-[A-Za-z0-9-]+|xoxp-[A-Za-z0-9-]+|-----BEGIN RSA|-----BEGIN PRIVATE KEY|-----BEGIN OPENSSH PRIVATE KEY|(password|passphrase|secret|private_key)[[:space:]]*[:=][[:space:]]*[^[:space:]]{6,}|(key|token|secret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/]{40,}={0,2}'
if printf '%s' "$ADDED" | grep -Eq "$SECRET_PATTERNS" 2>/dev/null; then
    HITS="shape"
fi

# ── Detector 2: value fingerprints ────────────────────────────────────────────
# Salt and fingerprints are gitignored and local-only. An unsalted hash of a
# low-entropy secret is brute-forceable, which is why the salt is mandatory:
# without it this file would become the next version of the bug it prevents.
FP_FILE="${CC_SECRET_FINGERPRINTS:-$ROOT/secrets/.secret-fingerprints}"
SALT_FILE="${CC_SECRET_SALT:-$ROOT/secrets/.fingerprint-salt}"
if [ -s "$FP_FILE" ] && [ -s "$SALT_FILE" ] && command -v python3 &>/dev/null; then
    if printf '%s' "$ADDED" | python3 -c '
import hashlib, re, sys
try:
    salt = open(sys.argv[1], "rb").read().strip().decode("utf-8", "replace")
    want = {l.strip() for l in open(sys.argv[2]) if l.strip()}
except OSError:
    sys.exit(1)                      # unreadable -> degrade, never hard-fail
if not want:
    sys.exit(1)
text = sys.stdin.read()
# Candidate tokens: anything that could be a credential. Splitting on
# whitespace alone misses a value inside quotes, a table cell or a sentence
# ending in a period, which is exactly how these leaked.
for tok in set(re.split(r"[\s`\"'\''<>(),;|]+", text)):
    tok = tok.strip(".:!?*_[]{}")
    if len(tok) < 6:
        continue
    if hashlib.sha256((salt + tok).encode()).hexdigest() in want:
        sys.exit(0)                  # matched
sys.exit(1)
' "$SALT_FILE" "$FP_FILE" 2>/dev/null; then
        HITS="${HITS:+$HITS+}value"
    fi
fi

[ -n "$HITS" ] || exit 0

# ── Report, naming files only ─────────────────────────────────────────────────
# The matched line is never printed: echoing it would put the credential into
# the transcript and the scrollback, which is the exposure being prevented.
SUSPECT=$(git -C "$ROOT" diff --cached --name-only 2>/dev/null | head -20)
{
    echo "BLOCKED (CFG-652): the staged diff contains something that looks like a credential (${HITS} match)."
    echo "Staged file(s):"
    printf '%s\n' "$SUSPECT" | sed 's/^/  /'
    echo ""
    echo "The matched value is deliberately NOT shown — printing it here would put it in the"
    echo "transcript and the scrollback, which is the exposure this guard exists to prevent."
    echo ""
    echo "Record a secret's location or fingerprint, never its value. Remove the value from the"
    echo "staged content, then commit again. If this is a false positive, unstage the file, confirm"
    echo "what it contains, and stage the corrected version — do not bypass the guard (CFG-513)."
} >&2
exit 2
