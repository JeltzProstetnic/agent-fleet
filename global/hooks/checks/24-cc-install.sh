#!/usr/bin/env bash
# Check group 24: Claude Code install invariants vs the last-known-good snapshot.
#
# Runs EVERY SessionStart, UNGATED. cc-install-invariants.sh reads the filesystem only
# (milliseconds, no npm, no cc-mirror, no network), so there is nothing to protect with a
# daily marker. The marker that gates check 4.6 exists to protect a 5-second `npm view`;
# on 2026-09-23 it had been spent at 10:56, four hours before `cc-mirror update` reset the
# install from 2.1.274 to 2.1.1 with exit 0 — so no session that day could have been told.
# A dead network changes nothing here.
#
# Contract: FAIL lines (DOWNGRADE, UNREQUESTED, LAUNCHER, VARIANT, RANGE, SETTINGS,
# UNKNOWN) go to WARNINGS with their measured values. With no snapshot the script writes
# a baseline and this check stays quiet. No cc-mirror install → nothing to check.
# Shared vars used: CONFIG_REPO, CC_MIRROR_DIR, WARNINGS

_ci_script="${CONFIG_REPO:-}/setup/scripts/cc-install-invariants.sh"
_ci_mirror="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"
if [ -f "$_ci_script" ] && [ -d "$_ci_mirror" ]; then
    _ci_snap="${CC_INSTALL_SNAPSHOT:-${XDG_CACHE_HOME:-$HOME/.cache}/cfg-agent-fleet/cc-install.snapshot}"
    _ci_tmpl="${CC_SETTINGS_TEMPLATE:-$CONFIG_REPO/setup/config/settings.json}"
    _ci_launcher="${CC_LAUNCHER:-$HOME/.local/bin/mclaude}"
    _ci_to=""
    command -v timeout >/dev/null 2>&1 && _ci_to="timeout ${CC_INSTALL_CHECK_TIMEOUT:-20}"
    _ci_out=""
    _ci_out=$(CC_MIRROR_DIR="$_ci_mirror" CC_LAUNCHER="$_ci_launcher" CC_INSTALL_SNAPSHOT="$_ci_snap" \
              CC_SETTINGS_TEMPLATE="$_ci_tmpl" $_ci_to bash "$_ci_script" --write-snapshot 2>/dev/null) || true
    _ci_fails=$(printf '%s\n' "$_ci_out" | grep '^FAIL:' | sed 's/^FAIL: //' | tr '\n' ';' | sed 's/;$//')
    if [ -z "$_ci_out" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }CC_INSTALL: invariants check produced no output (crashed or timed out) — the Claude Code install under $_ci_mirror is unverified this session. Run by hand: bash $_ci_script"
    elif [ -n "$_ci_fails" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }CC_INSTALL: the Claude Code install under $_ci_mirror FAILS its invariants — $_ci_fails. Full report: bash $_ci_script. Repair or update ONLY with bash $CONFIG_REPO/setup/scripts/cc-update.sh after /exit (never a cc-mirror verb). If the change was deliberate, accept it: bash $_ci_script --write-snapshot --force"
    fi
fi
