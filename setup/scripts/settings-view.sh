#!/usr/bin/env bash
# settings-view.sh — print the LIVE Claude Code settings.json with env values masked (CFG-892).
#
# Why: the live settings.json is a credential store — its env block carries tokens
# (AFD_TOKEN and others) next to ordinary config. A subagent asked to "read the settings"
# printed them into its transcript (2026-10-30). vault-read-guard.sh now blocks
# raw reads of the live file and points here.
#
# Masking rule: an env key the fleet settings TEMPLATE declares is shown with its live value —
# the template must never hold a secret (json-merge.py invariant), so its keys are policy, not
# credentials. Every other env value prints as "<masked: N chars>". If the template cannot be
# read, EVERY env value is masked (fail closed). Everything outside env prints unchanged.
#
# Usage: settings-view.sh [--file <settings.json>] [--template <template settings.json>]
#   default file:     $CLAUDE_CONFIG_DIR/settings.json (else ~/.claude/settings.json)
#   default template: <this repo>/setup/config/settings.json
# Pipe into jq for a part: settings-view.sh | jq .hooks

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
TEMPLATE="$HERE/../config/settings.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)     FILE="${2:-}"; shift 2 ;;
        --template) TEMPLATE="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "settings-view: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

[[ -f "$FILE" ]] || { echo "settings-view: settings file not found: $FILE" >&2; exit 1; }

python3 - "$FILE" "$TEMPLATE" <<'PY'
import json, sys
live_path, tmpl_path = sys.argv[1], sys.argv[2]
try:
    live = json.load(open(live_path))
except (OSError, ValueError) as e:
    sys.exit(f"settings-view: cannot parse {live_path}: {type(e).__name__}")
try:
    policy = set((json.load(open(tmpl_path)).get("env") or {}).keys())
except (OSError, ValueError):
    policy = set()
    print(f"settings-view: template unreadable ({tmpl_path}) — masking EVERY env value", file=sys.stderr)
env = live.get("env")
if isinstance(env, dict):
    live["env"] = {k: (v if k in policy else f"<masked: {len(str(v))} chars>") for k, v in env.items()}
print(json.dumps(live, indent=2))
PY
