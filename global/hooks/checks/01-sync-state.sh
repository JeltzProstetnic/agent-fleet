#!/usr/bin/env bash
# Check group 1: Sync state — sync failures, symlinks, template markers, repo existence
# Checks: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6
# Shared vars used: CONFIG_REPO, FAIL_MARKER, WARNINGS, PROJECT_ROOT

# Check 1.1: Did the last auto-sync fail?
if [ -f "$FAIL_MARKER" ]; then
    stage=$(grep '^stage=' "$FAIL_MARKER" | cut -d= -f2)
    time=$(grep '^time=' "$FAIL_MARKER" | cut -d= -f2-)
    detail=$(grep '^detail=' "$FAIL_MARKER" | cut -d= -f2-)
    WARNINGS="CONFIG SYNC FAILED ($CONFIG_REPO) at $time — stage: $stage, detail: $detail. Run 'bash $CONFIG_REPO/sync.sh status' to diagnose. Uncommitted config changes may exist in $CONFIG_REPO/."
fi

# Check 1.2: Are symlinks intact? + direction validation
if [ ! -L "$HOME/.claude/CLAUDE.md" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }CLAUDE.md is not symlinked to config repo. Run 'bash $CONFIG_REPO/sync.sh setup' to restore."
elif [ -L "$HOME/.claude/CLAUDE.md" ]; then
    _link_target="$(readlink -f "$HOME/.claude/CLAUDE.md" 2>/dev/null || echo "")"
    _config_real="$(readlink -f "$CONFIG_REPO" 2>/dev/null || echo "$CONFIG_REPO")"
    if [ -n "$_link_target" ] && [[ "$_link_target" != "$_config_real"/* ]]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }CLAUDE.md symlink points to wrong repo: $_link_target (expected under $_config_real). Run 'bash $CONFIG_REPO/sync.sh setup' to fix."
    fi
fi

# Check 1.3: Validate symlink direction for key subdirectories
for _subdir in foundation reference knowledge domains; do
    _link_path="$HOME/.claude/$_subdir"
    if [ -L "$_link_path" ]; then
        _sub_target="$(readlink -f "$_link_path" 2>/dev/null || echo "")"
        _config_real="${_config_real:-$(readlink -f "$CONFIG_REPO" 2>/dev/null || echo "$CONFIG_REPO")}"
        if [ -n "$_sub_target" ] && [[ "$_sub_target" != "$_config_real"/* ]]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }$_subdir symlink points to wrong repo: $_sub_target (expected under $_config_real). Run 'bash $CONFIG_REPO/sync.sh setup' to fix."
        fi
    fi
done

# Check 1.4: Detect template-only deployment and provide guidance (skip in first-run)
if [ -f "$CONFIG_REPO/.template-repo" ] && [ "${FIRST_RUN_MODE:-0}" -ne 1 ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }Config repo is a template-only deployment ($CONFIG_REPO has .template-repo marker). After first-run setup, delete it: rm $CONFIG_REPO/.template-repo. See foundation/first-run-refinement.md for guidance."
fi

# Check 1.5: Detect .setup-pending marker (first-run after install)
if [ -f "$PROJECT_ROOT/.setup-pending" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }SETUP_PENDING: First-run setup not yet completed (.setup-pending marker found). Load foundation/first-run-refinement.md and actively guide the user through machine setup, profile creation, and MCP credential configuration. Do NOT wait for the user to ask — initiate setup immediately."
fi

# Check 1.6: Does config repo exist?
if [ ! -d "$CONFIG_REPO/.git" ]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }Config repo not found at $CONFIG_REPO. Clone it and run: bash $CONFIG_REPO/sync.sh setup"
fi
