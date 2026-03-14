#!/usr/bin/env bash
# Migration v0.3: Split mixed files into framework + user layers
# Idempotent — safe to re-run.
#
# Usage: bash migrations/v0.3.sh [repo_dir]
#   repo_dir: optional, defaults to parent of this script's directory

set -euo pipefail

# Determine repo directory
if [[ -n "${1:-}" ]]; then
    REPO_DIR="$1"
else
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source lib.sh for logging (fall back to minimal stubs)
if [[ -f "$REPO_DIR/setup/lib.sh" ]]; then
    source "$REPO_DIR/setup/lib.sh"
else
    log_info()  { echo "[INFO] $*"; }
    log_warn()  { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

TARGET_VERSION="0.3"

log_info "Migration v0.3: Split mixed files into framework + local layers"

# ── 1. Extract hostname case entries to sync.local.sh ────────────────────────

if [[ ! -f "$REPO_DIR/sync.local.sh" ]]; then
    # Check if sync.sh has real (non-commented) hostname entries in the case block
    # Real entries are lines matching:  <whitespace><hostname-pattern>)<whitespace>machine_file=
    # Commented entries start with #
    if grep -qP '^\s+[^#\s].*\)\s+machine_file=' "$REPO_DIR/sync.sh" 2>/dev/null; then
        log_info "Extracting hostname mappings to sync.local.sh..."

        # Extract the case entries between 'case "$hn" in' and 'esac'
        # We build sync.local.sh with a function that contains the case block
        {
            cat << 'HEADER'
#!/usr/bin/env bash
# sync.local.sh — User-specific overrides for sync.sh
# This file is gitignored and never touched by upgrades.

# Map hostname to machine file name
# Called by sync.sh cmd_setup() when auto-detecting machine
local_hostname_map() {
    local hn="$1"
HEADER
            # Extract the case block from sync.sh (case "$hn" in ... esac)
            # Use awk to capture between 'case "$hn"' and the matching 'esac'
            # Convert 'machine_file="X"' assignments to 'echo "X"' for command substitution
            awk '
                /case "\$hn" in/ { capture=1 }
                capture {
                    line = $0
                    gsub(/machine_file=/, "echo ", line)
                    print "    " line
                }
                capture && /esac/ { capture=0 }
            ' "$REPO_DIR/sync.sh"

            cat << 'FOOTER'
}

# Post-setup hook — runs after cmd_setup() completes standard steps
# Uncomment and customize as needed:
# local_post_setup() {
#     # Example: MCP config symlink
#     # ln -sfn "$HOME/.cc-mirror/mclaude/config/.mcp.json" "$HOME/.mcp.json"
#     # log_info "Linked MCP config"
# }
FOOTER
        } > "$REPO_DIR/sync.local.sh"
        chmod +x "$REPO_DIR/sync.local.sh"
        log_info "Created sync.local.sh with hostname mappings"
    else
        log_info "No real hostname entries found in sync.sh — skipping sync.local.sh"
    fi
else
    log_info "sync.local.sh already exists — skipping"
fi

# ── 2. Split personas into framework defaults + personas.local.md ────────────

PERSONAS="$REPO_DIR/global/foundation/personas.md"
PERSONAS_LOCAL="$REPO_DIR/global/foundation/personas.local.md"

if [[ ! -f "$PERSONAS_LOCAL" ]] && [[ -f "$PERSONAS" ]]; then
    # Check if personas.md has non-default content
    # Default personas have "### Assistant" and "### Supporter" — anything else is custom
    if ! grep -q '### Assistant' "$PERSONAS" 2>/dev/null; then
        log_info "Extracting user personas to personas.local.md..."

        # Move current personas to local file
        cp "$PERSONAS" "$PERSONAS_LOCAL"
        log_info "Created personas.local.md with user personas"

        # Backup before destructive overwrite
        cp "$PERSONAS" "${PERSONAS}.bak"
        log_info "Backed up personas.md → personas.md.bak"

        # Replace personas.md with framework defaults + @import
        cat > "$PERSONAS" << 'FWEOF'
# Default Personas

These personas are active on all machines unless a machine file provides its own `## Persona` section.

Customize these to match your communication preferences. During first-run refinement, the agent will offer to help you create personalized personas.

## Persona

### Assistant
- **Name**: Assistant
- **Traits**: efficient, helpful, clear, thorough
- **Activates**: default
- **Color**: cyan
- **Style**: Gets the job done. Professional, clear, and concise. Focuses on delivering results with minimal overhead.

### Supporter
- **Name**: Supporter
- **Traits**: warm, encouraging, validating, patient
- **Activates**: when user is frustrated, exasperated, angry, or stuck. Stay active until user's tone clearly shifts back to calm/task-focused
- **Color**: green
- **Style**: Encouraging and confident. Validates the user's frustrations, offers perspective, and gently steers back to productive solutions. Uses humor to lighten the mood when appropriate. Never dismissive, never condescending.

<!-- User persona overrides loaded from local file (gitignored, survives updates) -->
@~/.claude/foundation/personas.local.md
FWEOF
        log_info "Replaced personas.md with framework defaults + @import"
    else
        log_info "personas.md already has default personas — skipping split"
    fi
else
    if [[ -f "$PERSONAS_LOCAL" ]]; then
        log_info "personas.local.md already exists — skipping"
    fi
fi

# ── 3. Add .gitignore entries ────────────────────────────────────────────────

GITIGNORE="$REPO_DIR/.gitignore"
for pattern in "sync.local.sh" "global/foundation/personas.local.md" "setup/config/settings.override.json"; do
    if ! grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then
        echo "$pattern" >> "$GITIGNORE"
        log_info "Added $pattern to .gitignore"
    fi
done

# ── 4. Set version ──────────────────────────────────────────────────────────

echo "$TARGET_VERSION" > "$REPO_DIR/.agent-fleet-version"
log_info "Version set to $TARGET_VERSION"

log_info "Migration v0.3 complete."
