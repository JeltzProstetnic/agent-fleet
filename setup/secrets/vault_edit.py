#!/usr/bin/env python3
"""The key-tree program behind `vault-manage.sh unset` and `keys` (CFG-1008).

Called only by vault-manage.sh, which decrypts the vault into a tmpfs scratch file and names it
in VAULT_TREE_PLAIN. Prints key NAMES, deploy_to targets and counts — never a value.

  keys [<pattern>]         names under a dotted prefix; no * means "starts with" (keys ppx_survey_).
  unset [--yes] <key>...   every key is checked against the vault as it was BEFORE anything is
                           removed: one malformed or absent key refuses the lot, nothing written. A
                           last segment `prefix*` (a literal prefix of at least 3 characters, so
                           never a bare *) matches every sibling it fits; without --yes a pattern
                           only previews the names and writes nothing (exact keys need no --yes).
                           A parent a removal leaves empty is pruned and named — the inverse of
                           `set`, which creates parents — so set+unset round-trips; an object that
                           was already empty is left alone. _meta is never removed: a pattern never
                           matches it and an exact `_meta` or `_meta.<field>` is refused.

Moved out of vault-manage.sh's heredoc unchanged in behaviour (CFG-1008 review, round 2), plus
the --yes preview, the 3-character prefix and the _meta refusal.
"""
import json
import os
import re
import sys

MIN_PREFIX = 3   # a shorter literal prefix before the * matches too broadly to remove on a pattern

mode, args = sys.argv[1], sys.argv[2:]
plain, DUPS = os.environ["VAULT_TREE_PLAIN"], []


def pairs(kv):  # json keeps the LAST of a duplicated key; record the name so a rewrite says so
    out = {}
    for k, v in kv:
        if k in out:
            DUPS.append(k)
        out[k] = v
    return out


data, MISSING = json.load(open(plain, encoding="utf-8"), object_pairs_hook=pairs), object()
if DUPS:
    print("  [WARN] duplicate key(s) in the vault: %s — json reads only the last copy;%s" % (
        ", ".join(dict.fromkeys(DUPS)), " this rewrite drops the earlier ones (older ciphertexts"
        " stay in git history)" if mode == "unset" else " the earlier ones are invisible to every tool"),
        file=sys.stderr)


def get(path):
    node = data
    for p in path:
        if not isinstance(node, dict) or p not in node:
            return MISSING
        node = node[p]
    return node


def matches(path):  # names under path[:-1] that the last segment's * pattern matches
    parent = get(path[:-1])
    rx = re.compile(".*".join(map(re.escape, path[-1].split("*"))) + r"\Z")
    return sorted(n for n in (parent if isinstance(parent, dict) else {}) if rx.match(n) and n != "_meta")


def own(node):  # the deploy_to target(s) a dict names itself: a string or a list of strings
    t = node.get("deploy_to") if isinstance(node, dict) else None
    return [x for x in ([t] if isinstance(t, str) else t if isinstance(t, list) else []) if isinstance(x, str)]


def below(node):  # own targets plus every target inside the subtree
    if not isinstance(node, dict):
        return []
    return own(node) + [t for k, v in node.items() if k != "deploy_to" for t in below(v)]


def keys(pat):
    path = pat.split(".") if pat else [""]
    if any("*" in p for p in path[:-1]):
        sys.exit("ERROR: %s — a * goes in the last segment only." % pat)
    if "*" not in path[-1]:
        path[-1] += "*"
    names = matches(path)
    for n in names:
        v, full = get(path[:-1] + [n]), ".".join(path[:-1] + [n])
        print("  %s: [%s]" % (full, ", ".join(sorted(v))) if isinstance(v, dict) else "  %s" % full)
    print("%d key(s) match %s" % (len(names), pat or "(all)"))


def bad(k):  # an empty segment, a * before the last segment, or a * after fewer than 3 literal chars
    segs = k.split(".")
    last = segs[-1]
    return "" in segs or any("*" in s for s in segs[:-1]) or ("*" in last and len(last.split("*")[0]) < MIN_PREFIX)


def remove(k):
    path = k.split(".")
    if get(path) is MISSING:
        print("  [OK] %s already gone with an ancestor removed or pruned in this call" % k)
        return
    chain = [data]
    for p in path[:-1]:
        chain.append(chain[-1][p])
    for t in dict.fromkeys([t for c in chain[1:] for t in own(c)] + below(get(path))):
        print("  [NOTE] %s had deploy_to: %s — deployed copies are NOT touched" % (k, t))
    del chain[-1][path[-1]]
    print("  [OK] removed %s (value not shown)" % k)
    for i in range(len(path) - 1, 0, -1):  # prune parents this removal emptied, never the root
        if chain[i]:
            break
        del chain[i - 1][path[i - 1]]
        print("  [OK] pruned %s — the removal left it empty" % ".".join(path[:i]))


def refuse_bad(args):  # malformed keys and _meta: refused before the vault is even looked at
    malformed = [k for k in args if bad(k)]
    if malformed:
        sys.exit("ERROR: malformed key(s): %s — a * goes only in the last segment, after a literal"
                 " prefix of at least %d characters (ppx_survey_*). Nothing removed, nothing written."
                 % (", ".join(malformed), MIN_PREFIX))
    meta = [k for k in args if k.split(".")[0] == "_meta"]
    if meta:
        sys.exit("ERROR: %s — _meta is the vault's own metadata, not a credential; unset never removes"
                 " it. Nothing removed, nothing written." % ", ".join(meta))


def resolve(args):  # → (keys to remove, the per-pattern match lines); refuses on any absent key
    todo, absent, matched = [], [], []
    for k in args:
        path = k.split(".")
        hits = matches(path) if "*" in path[-1] else None
        if hits:
            matched.append("  [OK] %s matched: %s" % (k, ", ".join(hits)))
            todo += [".".join(path[:-1] + [n]) for n in hits]
        elif hits == [] or get(path) is MISSING:
            absent.append(k + (" (matches nothing)" if hits == [] else ""))
        else:
            todo.append(k)
    if absent:
        sys.exit("ERROR: not in the vault: %s — nothing removed, nothing written." % ", ".join(absent))
    return list(dict.fromkeys(todo)), matched


def unset(args):
    yes = "--yes" in args
    args = list(dict.fromkeys(a for a in args if a != "--yes"))
    if not args:
        sys.exit("ERROR: no key named — nothing removed, nothing written.")
    refuse_bad(args)
    todo, matched = resolve(args)
    if matched and not yes:
        for line in matched:
            print(line.replace("[OK]", "[PREVIEW]", 1), file=sys.stderr)
        sys.exit("PREVIEW ONLY: a pattern would remove the %d key(s) %s — nothing removed, nothing"
                 " written. Check the names, then re-run with --yes (exact keys need no --yes)."
                 % (len(todo), ", ".join(todo)))
    for line in matched:
        print(line)
    for k in todo:
        remove(k)
    with open(plain, "w", encoding="utf-8") as f:  # raw UTF-8 stays raw, not \u escapes
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("  %d vault keys remain (top level, _meta not counted)" % len([k for k in data if k != "_meta"]))


if mode == "keys":
    keys(args[0] if args else "")
else:
    unset(args)
