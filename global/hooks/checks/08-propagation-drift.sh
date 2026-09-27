#!/usr/bin/env bash
# Check group 8: Real-time propagation drift — personal vs template repo
# Checks: 34, 34b (CFG-613: failing propagation, with its age)
# Shared vars used: CONFIG_REPO, WARNINGS
#
# Complements Check 4.5 (which surfaces PREVIOUS session's drift log from .sync-warnings.log).
# This check does a real-time diff of "Must Be Identical" files from the manifest,
# catching drift even when the previous session didn't shut down cleanly.

# Check 8.1: Compare "Must Be Identical" manifest files between personal and template
_TEMPLATE_DIR="$HOME/agent-fleet"
_MANIFEST="$CONFIG_REPO/template-sync-manifest.md"

if [ -d "$_TEMPLATE_DIR" ] && [ -f "$_MANIFEST" ]; then
    _DRIFT_FILES=""
    _DRIFT_COUNT=0

    # Extract file paths from "Must Be Identical" section only
    # Section starts with "## Tracked Files — Must Be Identical" and ends at next "## "
    _IN_SECTION=0
    while IFS= read -r _line; do
        # Detect section boundaries
        case "$_line" in
            "## Tracked Files — Must Be Identical"*) _IN_SECTION=1; continue ;;
            "## "*) [ "$_IN_SECTION" -eq 1 ] && break ;;
        esac
        [ "$_IN_SECTION" -eq 1 ] || continue

        # Parse table rows: | `file/path` | `hash` | date |
        # Skip header row and separator
        case "$_line" in
            "| File "*|"| "*"---"*|"") continue ;;
        esac

        # Extract file path from backtick-quoted first column
        _file_path=$(echo "$_line" | sed -n 's/^| *`\([^`]*\)`.*/\1/p')
        [ -n "$_file_path" ] || continue

        _personal="$CONFIG_REPO/$_file_path"
        _template="$_TEMPLATE_DIR/$_file_path"

        # Both files must exist for comparison
        [ -f "$_personal" ] && [ -f "$_template" ] || continue

        if ! diff -q "$_personal" "$_template" >/dev/null 2>&1; then
            _DRIFT_FILES="${_DRIFT_FILES:+$_DRIFT_FILES, }$_file_path"
            _DRIFT_COUNT=$((_DRIFT_COUNT + 1))
        fi
    done < "$_MANIFEST"

    if [ "$_DRIFT_COUNT" -gt 0 ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }PROPAGATION_DRIFT: $_DRIFT_COUNT file(s) differ between personal and template: $_DRIFT_FILES. Run 'bash $CONFIG_REPO/sync.sh check' for details."
    fi
fi

# Check 8.2 (CFG-613): a FAILING propagation is its own warning, naming its age.
# .template-push-failed is written by SessionEnd Phase 0.8 on any non-zero
# template-push exit and removed by the next success. Before this check it was
# never read at startup: the only signal was one TEMPLATE_PUSH_FAILED entry inside
# the generic drift line above, identical on day one and day six. Independent of
# the template dir existing — a marker means propagation is broken, full stop.
_TPF="$CONFIG_REPO/.template-push-failed"
if [ -f "$_TPF" ]; then
    _tpf_get() { awk -v k="$1" '/^output_tail=/{exit} index($0, k "=")==1 {print substr($0, length(k)+2); exit}' "$_TPF"; }
    _tpf_rc=$(_tpf_get exit_code); _tpf_n=$(_tpf_get consecutive)
    _tpf_since=$(_tpf_get first_failed); [ -n "$_tpf_since" ] || _tpf_since=$(_tpf_get time)
    _tpf_epoch=$(_tpf_get first_failed_epoch)
    case "$_tpf_epoch" in
        ''|*[!0-9]*) _tpf_epoch=$(date -u -d "$_tpf_since" +%s 2>/dev/null \
                         || date -j -u -f '%Y-%m-%d %H:%M:%S UTC' "$_tpf_since" +%s 2>/dev/null) ;;
    esac
    _tpf_age=""
    if [ -n "$_tpf_epoch" ]; then
        _tpf_s=$(( $(date +%s) - _tpf_epoch ))
        if [ "$_tpf_s" -ge 86400 ]; then _tpf_age=" — $((_tpf_s / 86400)) day(s) ago"
        else _tpf_age=" — $((_tpf_s / 3600)) hour(s) ago"; fi
    fi
    # Held files are the "    - path" lines of the kept output tail (template-push prints them last).
    _tpf_held=$(sed -n '/^output_tail=/,$p' "$_TPF" | sed 's/\x1b\[[0-9;]*m//g' \
        | sed -n 's/^.*\]     - \(.*\)$/\1/p' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    # CFG-664: an exit 3 can hold nothing - template registrations that arm no hook force it alone.
    _tpf_orph=$(sed -n '/^output_tail=/,$p' "$_TPF" | sed 's/\x1b\[[0-9;]*m//g' \
        | sed -n 's/^.*Orphan registrations: [0-9]* .* arm no hook: \(.*\); exit 3$/\1/p' | head -1)
    case "$_tpf_rc" in
        1) _tpf_why="hard abort, nothing propagated" ;;
        3) if [ -n "$_tpf_held" ] || [ -z "$_tpf_orph" ]; then _tpf_why="partial, held files did not propagate"
           else _tpf_why="partial, the template's settings.json registers hooks it does not have"; fi ;;
        *) _tpf_why="failed" ;;
    esac
    WARNINGS="${WARNINGS:+$WARNINGS | }TEMPLATE_PUSH_FAILING: template propagation has failed ${_tpf_n:-1} consecutive shutdown(s), since ${_tpf_since:-unknown}${_tpf_age}; last exit=${_tpf_rc:-?} (${_tpf_why})${_tpf_held:+; held: $_tpf_held}${_tpf_orph:+; orphan registrations: $_tpf_orph}. Every downstream fleet is that far behind — this is not routine drift. Read $_TPF, fix the cause, then run 'bash $CONFIG_REPO/sync.sh template-push --dry-run'."
    unset -f _tpf_get
fi
