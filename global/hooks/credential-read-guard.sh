#!/usr/bin/env bash
# PreToolUse hook (Read | Grep | NotebookRead): refuse a FILE tool aimed at a credential
# store (CFG-960). vault-read-guard.sh covers the Bash tool; this hook closes the door it
# left open — the Read tool had no PreToolUse matcher and live permissions.deny was [], so
# "read the settings" through Read printed the env block (tokens included) into the
# transcript, and .credentials.json, the live .mcp.json copies and ~/.git-credentials were
# covered by nothing at all.
#
# What is a credential store is NOT decided here: lib-credential-paths.sh holds the one list
# both guards use (settings | mcp | credentials | git | vault | nas), with the shapes, the
# ~ / $HOME / cwd-relative / .. / symlink resolution and the refusal texts. Each refusal
# names the safe alternative — settings-view.sh for a settings.json, "name the vault key,
# never the value" for the rest.
#
# Grep over a DIRECTORY that holds a credential file is refused outright, whatever glob or
# type filter the call carries. The alternative — accept a filter that provably excludes
# the files — needs ripgrep's glob dialect (brace sets, negation, **, type aliases)
# re-implemented here exactly; one mismatch is a leak, and refusing a Grep over ~ or
# $CLAUDE_CONFIG_DIR costs a narrower path. Grep without a path searches cwd and is judged
# on it. A directory with no credential file under it passes (the config repo, hooks/,
# knowledge/, any project) — and the config repo while secrets/vault.json is PLAINTEXT
# does not, which also says "encrypt it".
#
# Exit 2 + stderr = refuse. Exit 0 = allow. Nothing here reads a credential file's content.
# Without the lib (a broken deploy — sync.sh ships hook and lib in one loop) a
# credential-looking NAME is refused and everything else passes: a false block, never a read.

INPUT=$(cat)

# The five fields this hook reads — tool_name, cwd, file_path, notebook_path, path — as one
# record separated by \x1f (NUL cannot live in a bash variable). Three tiers, each tried
# until one yields a tool name (SF-A: a tier that cannot parse the payload must not end the
# hook with "no tool"): jq, then python3 — both real JSON parsers (escapes decoded, key order
# irrelevant; python writes with surrogatepass so a lone surrogate in a path cannot blank the
# record), one of the two is on every fleet machine (the corporate notebook has no jq; a Deck loses it on a
# SteamOS update) — then the textual last resort, which reads only the plain spelling and
# classifies on the whole payload: it can over-block a Write whose content spells a
# tool_name, never under-block a Read.
_textfield() { printf '%s' "$INPUT" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'; }
_fields_jq() {
    printf '%s' "$INPUT" | jq -j '(.tool_input | if type == "object" then . else {} end) as $t
        | [.tool_name, .cwd, $t.file_path, $t.notebook_path, $t.path]
        | map(if type == "string" then . else "" end) | join("\u001f")' 2>/dev/null
}
_fields_py() {
    printf '%s' "$INPUT" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: d = {}
d = d if isinstance(d, dict) else {}
t = d.get("tool_input"); t = t if isinstance(t, dict) else {}
s = lambda v: v if isinstance(v, str) else ""
rec = "\x1f".join([s(d.get("tool_name")), s(d.get("cwd")), s(t.get("file_path")), s(t.get("notebook_path")), s(t.get("path"))])
sys.stdout.buffer.write(rec.encode("utf-8", "surrogatepass"))' 2>/dev/null
}
_fields_text() {
    local tool=""
    case "$INPUT" in
        *'"tool_name":"Read"'*|*'"tool_name": "Read"'*)                 tool=Read ;;
        *'"tool_name":"Grep"'*|*'"tool_name": "Grep"'*)                 tool=Grep ;;
        *'"tool_name":"NotebookRead"'*|*'"tool_name": "NotebookRead"'*) tool=NotebookRead ;;
    esac
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s' "$tool" "$(_textfield cwd)" "$(_textfield file_path)" "$(_textfield notebook_path)" "$(_textfield path)"
}
REC=""
command -v jq >/dev/null 2>&1 && REC=$(_fields_jq)
[ -n "${REC%%$'\x1f'*}" ] || { command -v python3 >/dev/null 2>&1 && REC=$(_fields_py); }
[ -n "${REC%%$'\x1f'*}" ] || REC=$(_fields_text)
F=(); IFS=$'\x1f' read -r -d '' -a F <<<"$REC" || true
TOOL="${F[0]:-}"; CWD="${F[1]:-}"; [ -n "$CWD" ] || CWD="$PWD"
case "$TOOL" in
    Read)         TARGET="${F[2]:-}" ;;
    NotebookRead) TARGET="${F[3]:-}" ;;
    Grep)         TARGET="${F[4]:-}"; [ -n "$TARGET" ] || TARGET="$CWD" ;;
    *)            exit 0 ;;
esac
[ -n "$TARGET" ] || exit 0

# ── without the lib: the crude superset, and a message that says what is missing ──
if ! source "$(dirname "${BASH_SOURCE[0]}")/lib-credential-paths.sh" 2>/dev/null \
   || ! type cred_kind_of_path >/dev/null 2>&1; then
    case "$(basename "$TARGET")" in
        *settings.json*|*.mcp.json*|*credentials*|*vault.json*)
            printf 'BLOCKED (CFG-960): %s looks like a credential store, and lib-credential-paths.sh is missing next to this hook, so it cannot be told from a safe copy. Redeploy (sync.sh deploy) to restore the exact list; until then name the vault key, never read the value.\n' "$TARGET" >&2
            exit 2 ;;
    esac
    exit 0
fi

# ── a file ───────────────────────────────────────────────────────────────────
EXPANDED=$(cred_expand_path "$TARGET" "$CWD")
if [ "$TOOL" != Grep ] || [ ! -d "$EXPANDED" ]; then
    if KIND=$(cred_kind_of_path "$TARGET" "$CWD"); then
        cred_refusal "$KIND" "$TARGET" >&2
        exit 2
    fi
    exit 0
fi

# ── Grep over a directory ────────────────────────────────────────────────────
HITS=$(cred_files_under "$TARGET" "$CWD")
if [ -n "$HITS" ]; then
    mapfile -t _files <<<"$HITS"
    cred_refusal dir "$TARGET" "${_files[@]}" >&2
    exit 2
fi
exit 0
