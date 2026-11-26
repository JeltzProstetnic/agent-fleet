#!/usr/bin/env bash
# CFG-541 — file a cross-project inbox item with a mandatory type tag.
#
# Why this script exists at all: the inbox is four queues sharing one file
# (fact / rule / work / fyi), written as identical lines, so a receiving session
# meets N items of unknown and wildly unequal cost and correctly starts none of
# them. The cheap items were never hard — they were unrecognisable. The tag is
# what makes the queue drainable, and a convention that has to be REMEMBERED is
# the kind that stops happening, so filing goes through here.
# Full reasoning: docs/design-inbox-routing.md
#
# Dispatch contract for the RECEIVING session:
#   fact → write the target file now, delete the item. No backlog entry, ever.
#   rule → Meta-Rules consent queue; only these legitimately wait on the owner.
#   work → promote to backlog.md.
#   fyi  → read, delete.
#   An item that names attachments: move each file to its permanent home (or delete it)
#   when the item is dispatched; the attachments dir is a mailbox, not an archive.
#
# Usage:
#   inbox-file.sh --project <name> --type <fact|rule|work|fyi> --body "<text>"
#                 [--priority P0|P1|P2|P3] [--summary "<short>"] [--source "<proj machine date>"]
#                 [--attach <file>]... [--repo <config-repo>] [--inbox <path>] [--registry <path>]
#   --attach copies a file (repeatable) into <repo>/cross-project/attachments/<project>/<date>-<name>
#   and names it in the item — for private material that must not wait in a swept tmp/ (CFG-1112).
#   --repo points the per-project files and the default registry at another repo
#   (a writer running from a different checkout, or a test sandbox) — CFG-1091.
set -uo pipefail

_repo_root() { cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd; }
REPO_ROOT="$(_repo_root)"

PROJECT=""; TYPE=""; BODY=""; PRIORITY="P2"; SUMMARY=""; SOURCE=""; FORCE=0
INBOX=""
REGISTRY=""
ATTACH=()

die() { echo "inbox-file: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --project)  PROJECT="${2:-}"; shift 2 ;;
        --type)     TYPE="${2:-}"; shift 2 ;;
        --body)     BODY="${2:-}"; shift 2 ;;
        --priority) PRIORITY="${2:-}"; shift 2 ;;
        --summary)  SUMMARY="${2:-}"; shift 2 ;;
        --source)   SOURCE="${2:-}"; shift 2 ;;
        --repo)     REPO_ROOT="${2:-}"; shift 2 ;;
        --inbox)    INBOX="${2:-}"; INBOX_EXPLICIT=1; shift 2 ;;
        --force)    FORCE=1; shift ;;
        --registry) REGISTRY="${2:-}"; shift 2 ;;
        --attach)   [ -n "${2:-}" ] || die "--attach needs a file"; ATTACH+=("$2"); shift 2 ;;
        -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
        *)          die "unknown argument: $1" ;;
    esac
done

[ -d "$REPO_ROOT" ] || die "--repo '$REPO_ROOT' is not a directory"
[ -n "$INBOX" ]    || INBOX="$REPO_ROOT/cross-project/inbox.md"
[ -n "$REGISTRY" ] || REGISTRY="$REPO_ROOT/registry.md"

# The library lives next to this script, so a --repo without setup/scripts (a sandbox,
# another checkout) still resolves it; INBOX_REPO / INBOX_REGISTRY tell it where the
# corpus and the registry are.
_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/inbox-lib.sh"
[ -f "$_lib" ] || _lib="$REPO_ROOT/setup/scripts/inbox-lib.sh"
if [ -f "$_lib" ]; then
    INBOX_REPO="$REPO_ROOT"
    INBOX_REGISTRY="$REGISTRY"
    # shellcheck disable=SC1090
    . "$_lib"
fi

[ -n "$PROJECT" ] || die "--project is required"
[ -n "$TYPE" ]    || die "--type is required (fact|rule|work|fyi)"
[ -n "$BODY" ]    || die "--body is required"

case "$TYPE" in
    fact|rule|work|fyi) : ;;
    *) die "invalid --type '$TYPE' (expected fact, rule, work or fyi)" ;;
esac

case "$PRIORITY" in
    P0|P1|P2|P3) : ;;
    *) die "invalid --priority '$PRIORITY' (expected P0..P3)" ;;
esac

# CFG-1112: check every attachment BEFORE anything is filed — an item pointing at a file
# that never arrived is worse than a refusal the filer can fix on the spot.
for _f in ${ATTACH[@]+"${ATTACH[@]}"}; do
    [ -f "$_f" ] && [ -r "$_f" ] || die "attachment is not a readable file: $_f"
done

# Validate the target against registry.md. Check 3.2b already warns about
# undeliverable tags AFTER filing; refusing at filing time is strictly better,
# because the filer is the only one who still knows what they meant.
# `new-project` is the reserved placeholder and stays legal (CFG-483).
if [ -f "$REGISTRY" ] && [ "$PROJECT" != "new-project" ]; then
    # CFG-1091 D3: a target registered as deleted (or listed under Removed Projects) has
    # no session left to read its inbox — oldnotes took mail for nine days after its
    # deletion because only the NAME was checked, never the status. Refuse and name the
    # successor: the filer is the one who still knows what the item is for.
    if command -v inbox_registry_dead >/dev/null 2>&1 && _dead=$(inbox_registry_dead "$PROJECT"); then
        _succ="${_dead#*|}"
        if [ -n "$_succ" ]; then
            die "project '$PROJECT' is registered as ${_dead%%|*} — nothing will ever read its inbox. Its successor is '$_succ': file there with --project $_succ."
        fi
        die "project '$PROJECT' is registered as ${_dead%%|*} — nothing will ever read its inbox, and $(basename "$REGISTRY") names no successor. Ask the owner where its work went."
    fi
    if command -v inbox_registry_all_names >/dev/null 2>&1; then
        _known=$(inbox_registry_all_names)
    else
        _known=$(sed -n '/^## Projects/,/^## [^P]/p' "$REGISTRY" \
            | sed -n 's/^| *\([A-Za-z0-9._/-]\+\) *|.*/\1/p' \
            | grep -vxE '\-+|Project' \
            | tr '[:upper:]' '[:lower:]' | sort -u)
    fi
    _want=$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]')
    if [ -n "$_known" ] \
       && ! printf '%s\n' "$_known" | grep -qxF "$_want" \
       && ! printf '%s\n' "$_known" | grep -qxF "${_want##*/}"; then
        die "project '$PROJECT' matches nothing in $(basename "$REGISTRY") — it would never be delivered. Fix the name or register the project."
    fi
fi

# CFG-542: new filings go to the per-project file. This is the half that kills the
# shared-file clobber — `git add cross-project/inbox.md` used to sweep up whatever
# other sessions had left uncommitted there (one commit carried 53 deletions it never
# made). Separate files make that structurally impossible. An explicit --inbox still
# wins, so callers that must target a specific file (tests, legacy tooling) can.
if [ -z "${INBOX_EXPLICIT:-}" ] && command -v inbox_project_file >/dev/null 2>&1; then
    _target="$(inbox_project_file "$PROJECT")"
    mkdir -p "$(dirname "$_target")" 2>/dev/null || die "cannot create $(dirname "$_target")"
    [ -f "$_target" ] || printf '# Inbox — %s\n\n' "$PROJECT" > "$_target"
    INBOX="$_target"
fi

[ -f "$INBOX" ] || die "inbox file not found: $INBOX"

# ── CFG-1112: --attach ──────────────────────────────────────────────────────
# tmp-sweep deleted a project's private notes on 2026-11-19 while they waited in tmp/ for a hand-off
# that only an inbox line pointed at. The copy goes into the config repo itself, next to the inbox,
# under the same safe name the project's inbox file uses; never overwritten, verified byte for byte.
_attach_safe() { printf '%s' "$1" | sed -e 's#[^A-Za-z0-9._-]#_#g' -e 's#^[._-]*##'; }
_attached=()
if [ "${#ATTACH[@]}" -gt 0 ]; then
    if command -v inbox_project_file >/dev/null 2>&1; then
        _adir_name="$(basename "$(inbox_project_file "$PROJECT")" .md)"
    else
        _adir_name="$(_attach_safe "$(printf '%s' "$PROJECT" | tr '[:upper:]/' '[:lower:]-')")"
    fi
    _adir="$REPO_ROOT/cross-project/attachments/${_adir_name:-unrouted}"
    mkdir -p "$_adir" || die "cannot create $_adir"
    _today="$(date +%Y-%m-%d)"
    for _f in "${ATTACH[@]}"; do
        _name="$(_attach_safe "$(basename "$_f")")"; _name="${_name:-attachment}"
        _stem="$_name"; _ext=""
        case "$_name" in ?*.*) _stem="${_name%.*}"; _ext=".${_name##*.}" ;; esac
        _dest="$_adir/$_today-$_name"; _n=2
        while [ -e "$_dest" ] && ! cmp -s "$_dest" "$_f"; do
            _dest="$_adir/$_today-$_stem-$_n$_ext"; _n=$((_n + 1))
        done
        [ -e "$_dest" ] || cp -- "$_f" "$_dest" || die "could not copy $_f to $_dest"
        cmp -s "$_dest" "$_f" || die "copy of $_f at $_dest does not match the source"
        _attached+=("cross-project/attachments/${_adir_name:-unrouted}/$(basename "$_dest")")
    done
    _list=""
    for _a in "${_attached[@]}"; do _list="${_list:+$_list, }\`$_a\`"; done
    BODY="$BODY — attachments: $_list"
fi

# Assemble the item. Format is deliberately a superset of the pre-CFG-541 line so
# every existing consumer keeps working: the tag sits AFTER the closing `**`, which
# is where Check 3.2's delivery regex and 3.2b's tag extraction both stop reading.
_head="- [ ] **$PROJECT** [$TYPE] ($PRIORITY"
[ -n "$SUMMARY" ] && _head="$_head — $SUMMARY"
[ -n "$SOURCE" ]  && _head="$_head; from $SOURCE"
_head="$_head)"

# ── CFG-553: per-project inflow cap ─────────────────────────────────────────
# Type tags bound what a receiving session must THINK about; per-project files bound
# what it PAYS. Neither bounds what it RECEIVES. Measured inflow is ~12 items/day
# against a drain that happens perhaps monthly (301 → 163 → 187 over one week), so
# without a cap the queue regrows and every earlier fix is temporary.
#
# The cap is a speed bump, never a wall: `--force` always succeeds, because a session
# holding a real finding at shutdown must be able to record it. What the friction buys
# is that the cost of an over-full queue lands on the FILER, who still has the context
# to consolidate, instead of on a future receiver who does not.
#
# ── CFG-554: the cap binds the queueing types only ──────────────────────────
# The owner, 2026-08-27: "report to cfg that this mechanism is unacceptable. where else
# should other projects write???" That is right, and the fault is structural rather
# than a tuning problem. The cross-project boundary is a HARD rule — write inside
# your own directory, everything else through the inbox — so a blocking ceiling on
# that one channel leaves a project holding a correction to a canonical file with no
# legal path: --force is the behaviour the design calls the disease, its own backlog
# is where the owner never sees it, and a direct edit breaches the boundary.
#
# The fix rests on an asymmetry already in the dispatch contract at the top of this
# file. `fact` is execute-now-and-delete and `fyi` is read-and-delete: neither can
# accumulate unless the RECEIVER ignores it, so capping them puts the cost of the
# reader's backlog onto the writer, which is backwards. `work` and `rule` genuinely
# queue — work waits on a backlog slot, rule waits on the owner — so those keep the cap.
#
# The concrete case that surfaced it: contacts.md #29 carried a wrong Zenodo concept
# DOI that had already gone to an external researcher. One digit, unambiguous,
# data-integrity. The mechanism refused it.
_ceiling="${INBOX_PROJECT_CEILING:-25}"
_open=0
if [ "$_ceiling" -gt 0 ] 2>/dev/null; then
    _open=$(grep -ci -- "^- \[ \] \*\*[[:space:]]*$PROJECT[[:space:]]*\*\*" "$INBOX" 2>/dev/null | head -1)
    [ -n "$_open" ] || _open=0
fi

# ── CFG-559: the cap warns, it never refuses ────────────────────────────────
# The owner, 2026-09-10: "sessions have stopped reporting issues to other projects because
# they do not force without my say so."
#
# That is the design fault stated exactly. CFG-553 aimed the cost at the FILER so it
# would consolidate; CFG-554 already had to reopen fact/fyi when that misfired. The
# remaining work/rule wall kept failing the same way for a reason no amount of tuning
# reaches: the filer is a DIFFERENT project's session, and the only way through
# (--force) is an authority a session correctly refuses to grant itself. So the report
# was neither filed nor escalated — it died with the session, and the fleet looked
# quiet because reporting had broken rather than because nothing was wrong.
#
# It also corrupted the data it was meant to organise. A [rule] arrived in cfg's inbox
# carrying its own confession: "[rule] filings to this project are currently refused
# over the ceiling, so they arrive as a [fact]". Mislabelling to get past the wall
# destroys the type tag CFG-541 exists to make the dispatch mechanical.
#
# The asymmetry that settles it: a filed item can always be drained later, but an item
# that was never filed is gone. So the queue is the cheaper failure, every time.
# Backpressure stays — it just lands on the RECEIVER, the only party that can drain.
_over=0
if [ "$_ceiling" -gt 0 ] 2>/dev/null && [ "$_open" -ge "$_ceiling" ]; then
    _over=1
fi

# CFG-798: a target whose last line has no newline (seen: a trailing <!-- comment -->) would
# get the item glued onto that line, hidden from every sweep. Terminate it first.
if [ -s "$INBOX" ] && [ -n "$(tail -c 1 "$INBOX")" ]; then
    printf '\n' >> "$INBOX" || die "could not append to $INBOX"
fi
printf '%s: %s\n' "$_head" "$BODY" >> "$INBOX" || die "could not append to $INBOX"

# ── Verify what was actually written (lrn 2026-09-23, owner-approved) ────────────────────
# An item filed that day read "⇒ ** ist tracked und jetzt modified.**" — the filename was
# gone, because backticks in --body were run as COMMAND SUBSTITUTION by the CALLER's shell
# before this script ever saw them. Empty string, error to the caller's stderr, item filed
# anyway, nobody the wiser. Backtick identifiers are house style in inbox bodies, so this
# is structural rather than a one-off: four such items came out of a single session.
#
# Two checks, because the damage has two different origins:
#   (1) the write itself — read the line back and compare. A body carrying a newline
#       silently becomes SEVERAL lines, and the continuation lines have no `- [ ]` prefix,
#       so every sweep that counts open items misses them.
#   (2) the caller's shell — this script cannot see the pre-substitution text, so the only
#       available evidence is the scar: an emphasis or code span left empty where an
#       identifier used to be. Warn and name the cause; never refuse, because a report that
#       cannot be filed dies.
_written=$(tail -1 "$INBOX")
if [ "$_written" != "$_head: $BODY" ]; then
    cat >&2 <<EOF

inbox-file: WARNING — what was written does not match what was passed.

  passed : $(printf '%s' "$BODY" | head -c 160)
  written: $(printf '%s' "$_written" | head -c 160)

The item IS filed. If the body contained a newline it is now several lines, and the
continuation lines carry no '- [ ]' prefix — every sweep that counts open items will miss
them. Re-file it as a single line.
EOF
fi

case "$BODY" in
    *'**  **'*|*'** **'*|*'****'*|*'``'*|*'** ist'*)
        cat >&2 <<'EOF'

inbox-file: WARNING — this body carries the signature of command substitution.

An empty emphasis or code span usually means BACKTICKS in the --body argument were
executed by your shell before this script saw them, and the identifier between them is
gone. Quote the body with single quotes, or escape the backticks:

  --body 'the file `foo.sh` is tracked'      # single quotes: safe
  --body "the file \`foo.sh\` is tracked"     # double quotes: escape them

The item IS filed — check it and re-file if the text lost something.
EOF
        ;;
esac

echo "filed [$TYPE] $PRIORITY item for $PROJECT"
for _a in ${_attached[@]+"${_attached[@]}"}; do echo "  attached: $_a"; done
# --force is retained so existing callers keep working, but it no longer gates anything.
[ "$FORCE" -eq 1 ] && echo "  (--force is no longer needed: no filing is ever refused)"

if [ "$_over" -eq 1 ]; then
    cat >&2 <<EOF

inbox-file: WARNING — '$PROJECT' now holds $((_open + 1)) open item(s), over its ceiling of $_ceiling.

The item was filed. Nothing is ever refused: a report that cannot be filed dies with
the session holding it, while a queued one can still be drained.

Draining is '$PROJECT''s job, and only '$PROJECT' can do it:
  - dispatch its [fact] and [fyi] items at next session start — both are
    delete-on-read and usually clear most of a queue in minutes
  - [work] items belong in '$PROJECT''s backlog; [rule] items need the owner's consent

Ceiling is per project and tunable with INBOX_PROJECT_CEILING.
EOF
fi
exit 0
