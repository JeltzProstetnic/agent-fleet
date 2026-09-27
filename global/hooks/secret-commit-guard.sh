#!/usr/bin/env bash
# PreToolUse hook (CFG-652/653): scan the diff a `git commit` will RECORD for
# credentials, whoever issues it — the index always, and the working tree as
# well when the commit carries it: -a and named paths (CFG-668).
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
# It reads what the commit will record — never less, and more only where the
# base guard already read more (the index under `--only <path>`, and the call's
# own repo index when a `cd` moves the commit elsewhere) — and NOTHING ELSE.
# CFG-621 was a defect where vault-read-guard.sh blocked ordinary commits
# because the English word "more" appeared in an -m body; a guard that
# false-blocks trains the bypass (CFG-513). The commit message is never read.
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

# ── Resolve every commit in the command, its repo, and what it will record ────
# CFG-668: the guard used to read `git diff --cached` and nothing else, so a
# commit that stages and commits in one step — `-a`/`-am`, or `git commit
# <path>` — went through unexamined, and the suite had no such case to show it.
#
# The rule since the CFG-668 repair: the INDEX IS ALWAYS READ, exactly as the
# base guard did, and the working tree against HEAD is read IN ADDITION when a
# commit carries it (-a/--all, named paths, --pathspec-from-file, a pathspec
# the shell computes at run time). The first fix instead dropped the index
# whenever it believed it had seen a pathspec, and its word-splitter mistook
# `2>&1`, `>/dev/null`, `<<'EOF'`, a line continuation and a "(x)" inside a
# heredoc message for pathspecs — so a STAGED secret in an everyday commit
# shape was committed unscanned. Reading the index unconditionally means a
# parsing mistake can at worst over-read, never under-read what base read.
#
# Narrowness is kept where it is safe to keep: an ordinary commit reads the
# index only, the tree is read only for the paths the commit names, and a
# leading `cd DIR` decides which repo that is (the hook runs in the session's
# cwd, which is not where `cd ~/other && git commit -am …` commits).
#
# The command is parsed by lib-commit-scan.sh (python3, linear). Without a
# working python3, or without the lib, the guard falls back to the base clause
# walk below plus an -a heuristic: that degrades toward over-reading, never
# toward reading less than base.
JOBS=()   # flattened: J <dir> <n> <git-global-args…> <tree 0|1> <n> <paths…>
PARSED=0
# shellcheck source=lib-commit-scan.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-commit-scan.sh" 2>/dev/null \
    && _commit_scan_jobs "$CMD" && PARSED=1

# The base guard's clause walk, kept verbatim in effect: its target's index is
# ALWAYS read, so nothing the base guard scanned goes unscanned. Without python3
# it is the only parse, and a word that looks like -a also reads the tree.
_base_walk() {
    local clause local_c w all=0
    set -f
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
            shift
            if [ "$PARSED" -eq 0 ]; then
                for w in "$@"; do
                    case "$w" in --all|-a*|-[!-]*a*) all=1 ;; esac   # -a, -am, -qam …
                done
            fi
            set +f
            JOBS+=(J "${local_c:-$PWD}" 0 "$all" 0)
            return 0
        fi
    done < <(printf '%s\n' "$CMD" | tr '\n;|' '\n\n\n' | sed 's/&&/\n/g' | sed 's/^[[:space:]]*//')
    set +f
    return 0
}
_base_walk

[ ${#JOBS[@]} -gt 0 ] || exit 0

# ── Read what each commit will record ─────────────────────────────────────────
# --no-color because this fleet sets color.diff=always, which makes every `^+`
# match fail silently (a documented WSL trap). Pathspecs resolve against the
# commit's own directory, which is why the diffs run there and not at the root.
ADDED=""
NAMES=""
FP_ROOT=""
_seen=$'\n'
# _job_diff runs inside _scan_job and reads its locals: dir g index tree has_head paths.
_job_diff() {  # extra diff args (e.g. --name-only) first
    [ "$index" -eq 1 ] && git -C "$dir" "${g[@]}" diff --no-color "$@" --cached 2>/dev/null
    [ "$tree" = "1" ] || return 0
    if [ "$has_head" -eq 1 ]; then
        git -C "$dir" "${g[@]}" diff --no-color "$@" HEAD -- "${paths[@]}" 2>/dev/null
    else   # unborn branch: the index above plus unstaged edits is the same set
        git -C "$dir" "${g[@]}" diff --no-color "$@" -- "${paths[@]}" 2>/dev/null
    fi
    return 0
}
_scan_job() {  # _scan_job <dir> <tree> <n-globals> <globals…> <n-paths> <paths…>
    local dir="$1" tree="$2" ng="$3"; shift 3
    local g=("${@:1:$ng}"); shift "$ng"; shift   # drop n-paths: the rest are the paths
    local paths=("$@") ikey key root has_head=0 index=1
    # \x1f-joined, so "a b" (one path) and a b (two) never share a key
    ikey=$(printf '%s\x1f' "$dir" "${g[@]}"); key=$(printf '%s\x1f' "$ikey" "$tree" "${paths[@]}")
    case "$_seen" in *$'\n'"$key"$'\n'*) return 0 ;; esac
    case "$_seen" in *$'\n'"$ikey"$'\n'*) index=0 ;; esac   # this index is already read
    [ "$index" -eq 1 ] || [ "$tree" = "1" ] || return 0
    _seen+="$key"$'\n'"$ikey"$'\n'
    [ -d "$dir" ] || return 0
    root=$(git -C "$dir" "${g[@]}" rev-parse --show-toplevel 2>/dev/null) || return 0
    [ -n "$root" ] || return 0
    [ -n "$FP_ROOT" ] || FP_ROOT="$root"
    git -C "$dir" "${g[@]}" rev-parse --verify -q HEAD >/dev/null 2>&1 && has_head=1
    ADDED+=$(_job_diff | grep '^+' | grep -v '^+++' || true)$'\n'
    NAMES+=$(_job_diff --name-only)$'\n'
}
_i=0
while [ "$_i" -lt ${#JOBS[@]} ]; do
    [ "${JOBS[$_i]}" = "J" ] || break
    _dir="${JOBS[$((_i + 1))]}"; _ng="${JOBS[$((_i + 2))]}"
    _g=("${JOBS[@]:$((_i + 3)):$_ng}")
    _tree="${JOBS[$((_i + 3 + _ng))]}"; _np="${JOBS[$((_i + 4 + _ng))]}"
    _p=("${JOBS[@]:$((_i + 5 + _ng)):$_np}")
    _scan_job "$_dir" "$_tree" "$_ng" "${_g[@]}" "$_np" "${_p[@]}"
    _i=$((_i + 5 + _ng + _np))
done
[ -n "$FP_ROOT" ] || exit 0
ROOT="$FP_ROOT"

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
SECRET_PATTERNS='sk-ant-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|AIzaSy[A-Za-z0-9_-]{33}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|xoxb-[A-Za-z0-9-]+|xoxp-[A-Za-z0-9-]+|-----BEGIN RSA|-----BEGIN PRIVATE KEY|-----BEGIN OPENSSH PRIVATE KEY|(password|passphrase|secret|private_key)[[:space:]]*[:=][[:space:]]*[^[:space:]]{6,}|(key|token|secret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/]{40,}={0,2}'  # pragma: allowlist secret
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
SUSPECT=$(printf '%s\n' "$NAMES" | sed '/^$/d' | sort -u | head -20)
{
    echo "BLOCKED (CFG-652): this commit's diff contains something that looks like a credential (${HITS} match)."
    echo "File(s) in the commit:"
    printf '%s\n' "$SUSPECT" | sed 's/^/  /'
    echo ""
    echo "The matched value is deliberately NOT shown — printing it here would put it in the"
    echo "transcript and the scrollback, which is the exposure this guard exists to prevent."
    echo ""
    echo "Record a secret's location or fingerprint, never its value. Remove the value from the"
    echo "content being committed, then commit again. If this is a false positive, confirm what"
    echo "the file contains and commit the corrected version — do not bypass the guard (CFG-513)."
} >&2
exit 2
