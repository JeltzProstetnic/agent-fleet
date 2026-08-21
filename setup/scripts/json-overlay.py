#!/usr/bin/env python3
"""Deep merge a machine overlay JSON on top of a base JSON.

Usage: python3 json-overlay.py <base.json> <overlay.json>

Merge rules:
  - Dicts: recursive merge (overlay wins for scalars)
  - Lists: union (deduplicate, preserve order)
  - Scalars: overlay wins

Outputs merged JSON to stdout.
"""
import json
import sys


def deep_merge(base, overlay):
    """Merge overlay into base (mutates base). Returns base."""
    for k, v in overlay.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        elif k in base and isinstance(base[k], list) and isinstance(v, list):
            # Union: base items + overlay items not already in base
            base[k] = base[k] + [x for x in v if x not in base[k]]
        else:
            base[k] = v
    return base


def main():
    if len(sys.argv) != 3:
        print("Usage: json-overlay.py <base.json> <overlay.json>", file=sys.stderr)
        sys.exit(1)

    base = json.load(open(sys.argv[1]))
    overlay = json.load(open(sys.argv[2]))
    result = deep_merge(base, overlay)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
