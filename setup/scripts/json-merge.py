#!/usr/bin/env python3
"""Merge settings.json: base template + live config + optional override.

Usage: python3 json-merge.py <base> <live> <override>

- hooks, statusLine, spinnerTipsEnabled, enabledPlugins: base wins (authoritative)
- env: live preserved, base merged on top (secrets survive, new vars added)
- permissions.allow: union of both (deduped)
- live-only keys (effortLevel, etc.): preserved
- __HOME__ in base is substituted with $HOME from environment

Outputs merged JSON to stdout.
"""
import json
import os
import sys


def deep_merge(base, override):
    """Merge override into base dict (mutates base)."""
    for k, v in override.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        elif k in base and isinstance(base[k], list) and isinstance(v, list):
            base[k] = base[k] + [x for x in v if x not in base[k]]
        else:
            base[k] = v


def subst(obj, home):
    """Substitute __HOME__ in all string values."""
    if isinstance(obj, str):
        return obj.replace('__HOME__', home)
    if isinstance(obj, dict):
        return {k: subst(v, home) for k, v in obj.items()}
    if isinstance(obj, list):
        return [subst(v, home) for v in obj]
    return obj


def main():
    if len(sys.argv) != 4:
        print("Usage: json-merge.py <base> <live> <override>", file=sys.stderr)
        sys.exit(1)

    base_path, live_path, override_path = sys.argv[1], sys.argv[2], sys.argv[3]
    home = os.environ['HOME']

    base = json.load(open(base_path))
    live = json.load(open(live_path))

    # Apply override to base if exists
    if os.path.exists(override_path):
        over = json.load(open(override_path))
        deep_merge(base, over)

    # Substitute __HOME__ in all string values
    base = subst(base, home)

    # Start with live, then overlay base
    result = dict(live)

    # env: start with live (preserves secrets like AFD_TOKEN that aren't in base),
    # then overlay base vars (adds new vars, updates shared vars).
    # INVARIANT: base template must NEVER contain secret keys — secrets come from vault.
    merged_env = dict(live.get('env', {}))
    merged_env.update(base.get('env', {}))
    result['env'] = merged_env

    # permissions.allow: union of both, deduped
    live_perms = set(live.get('permissions', {}).get('allow', []))
    base_perms = set(base.get('permissions', {}).get('allow', []))
    result['permissions'] = live.get('permissions', {})
    result['permissions']['allow'] = sorted(live_perms | base_perms)

    # These sections: base is authoritative (latest hooks, structure)
    for key in ['hooks', 'statusLine', 'spinnerTipsEnabled', 'enabledPlugins']:
        if key in base:
            result[key] = base[key]

    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
