# Check group 8: Real-time propagation drift — personal vs template repo
# Checks: 34
# Shared vars used: CONFIG_REPO, WARNINGS
#
# Complements Check 13 (which surfaces PREVIOUS session's drift log from .sync-warnings.log).
# This check does a real-time diff of "Must Be Identical" files from the manifest,
# catching drift even when the previous session didn't shut down cleanly.

# Check 34: Compare "Must Be Identical" manifest files between personal and template
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
