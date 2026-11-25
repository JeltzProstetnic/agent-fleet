#!/usr/bin/env bash
# lib-pc-fixture.sh — fixtures shared by the project-conformance suites (CFG-1094).
# Sourced after test-helpers.sh (needs TEST_TMPDIR, HOME sandbox, REPO_ROOT).
#
# The spec under test is derived from the REAL templates and conf files of this repo
# (setup/projects/_templates, setup/config/*.conf), so fixtures only fabricate the
# PROJECT side: a git repo with a manifest, optionally carrying each drift shape.

PC_LIB="$REPO_ROOT/setup/scripts/project-conformance-lib.sh"
PC_CLI="$REPO_ROOT/setup/scripts/project-conformance.sh"
PC_TEMPLATE_HOOK="$REPO_ROOT/setup/projects/_templates/.githooks/pre-commit"
PC_MARKER='<!-- agent-fleet-managed: DO NOT run /init — this file is configured by agent-fleet -->'
PC_LEGACY_ROW='| `~/cfg-agent-fleet/cross-project/inbox.md` | Cross-project tasks |'

# pcf_cfg — a fixture config repo with a registry naming the projects the tests create.
# Sets PC_REGISTRY and PC_GLOBAL_CLAUDE (seams) and CFG_FIX. The fixture global CLAUDE.md
# has a conditional-loading table with NO knowledge row, so every type row is demanded unless
# a test adds rows with pcf_global_rows. Extra registry rows via pcf_register.
pcf_cfg() {
    CFG_FIX="$TEST_TMPDIR/cfg"
    mkdir -p "$CFG_FIX"
    cat > "$CFG_FIX/global-CLAUDE.md" <<'EOF'
# Global Claude Code Configuration (fixture)

6. **Conditional loading (do NOT load unless triggered):**

   | Trigger | File |
   |---------|------|
   | MCP issue, auth, first MCP use | `reference/mcp-catalog.md` |
EOF
    export PC_GLOBAL_CLAUDE="$CFG_FIX/global-CLAUDE.md"
    cat > "$CFG_FIX/registry.md" <<'EOF'
# Project Registry

## Machines

| Machine ID | Platform | Home | Location | Claude Code | Notes |
|-----------|----------|------|----------|-------------|-------|
| `box` | Linux | `/home/x/` | Home | Deployed | its path cell sits where a project's Path is |

## Projects

| Project | Priority | Parent | Path | GitHub Remote | Machines | Type | Phase | Notes |
|---------|----------|--------|------|--------------|----------|------|-------|-------|
EOF
    export PC_REGISTRY="$CFG_FIX/registry.md"
}

# pcf_global_rows <file.md>… — trigger rows naming knowledge/<file> in the fixture global CLAUDE.md
pcf_global_rows() {
    local f
    for f in "$@"; do printf '   | some trigger for %s | `knowledge/%s` |\n' "$f" "$f" >> "$CFG_FIX/global-CLAUDE.md"; done
}

# pcf_register <name> <path-with-~> <type> — one registry row
pcf_register() {
    printf '| %s | P2 | — | `%s` | x | box | %s | active | n |\n' "$1" "$2" "$3" >> "$CFG_FIX/registry.md"
}

# pcf_manifest <file> [opts…] — a code-type manifest. Opts: --no-marker, --legacy-inbox,
# --legacy-prose, --legacy-relative, --keep-mention, --knowledge <file.md>…, --crlf
pcf_manifest() {
    local f="$1"; shift
    local marker=1 legacy=0 prose=0 relative=0 keep=0 crlf=0 know=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-marker) marker=0 ;;
            --legacy-inbox) legacy=1 ;;
            --legacy-prose) prose=1 ;;
            --legacy-relative) relative=1 ;;
            --keep-mention) keep=1 ;;
            --knowledge) know+=("$2"); shift ;;
            --crlf) crlf=1 ;;
        esac
        shift
    done
    {
        [ "$marker" -eq 1 ] && printf '%s\n' "$PC_MARKER"
        printf '# Fixture project\n\nA fixture.\n\n## Knowledge Loading\n\n| Domain | Path | Load when... |\n|--------|------|-------------|\n'
        printf '| Software Development | `~/.claude/domains/software-development/tdd-protocol.md` | Writing code |\n'
        local k; for k in ${know[@]+"${know[@]}"}; do printf '| K | `~/.claude/knowledge/%s` | when |\n' "$k"; done
        printf '\n## Key Files\n\n| File | Purpose |\n|------|---------|\n| `backlog.md` | Backlog |\n\n'
        printf '## Active Roster\n\n| Agent Type | Use When |\n|-----------|----------|\n| general-purpose | Everything |\n\n'
        printf '## Reference\n\n- MCP catalog: `~/.claude/reference/mcp-catalog.md`\n\n## Project Structure\n\n| Directory | Contents |\n|-----------|----------|\n| `tmp/` | Throwaway |\n\n'
        printf '## Cross-Project References\n\n| File | Purpose |\n|------|---------|\n'
        printf '| `~/cfg-agent-fleet/cross-project/contacts.md` | Contact status tracking |\n'
        [ "$legacy" -eq 1 ] && printf '%s\n' "$PC_LEGACY_ROW"
        [ "$relative" -eq 1 ] && printf '| `cross-project/inbox.md` | One-off cross-project tasks (transient, picked up and deleted) |\n'
        [ "$keep" -eq 1 ] && printf '| `cross-project/inbox.md` | Legacy spillover queue — still read alongside the per-project files |\n'
        if [ "$prose" -eq 1 ]; then
            printf '\n## Rules\n\n- Never edit the sibling project from here; cross-project notes go via `~/cfg-agent-fleet/cross-project/inbox.md`.\n'
            printf '%s\n' '- Research mail → post task to `~/cfg-agent-fleet/cross-project/inbox.md` targeting **sibling**'
        fi
        local i; for i in $(seq 1 12); do printf 'filler line %s\n' "$i"; done
    } > "$f"
    [ "$crlf" -eq 1 ] && { sed -i 's/$/\r/' "$f"; }
    return 0
}

# pcf_project <name> [opts…] — git repo at $HOME/<name> with a committed manifest.
# Project opts: --no-gitignore, --gitignore-crlf, --tracked-tmp <n>, --githooks (template copy),
# --githooks-noexec, --githooks-custom, --dotclaude (manifest under .claude/), --no-manifest,
# --type <registry type> (default code; also registers the project when CFG_FIX exists).
# Manifest opts are passed through to pcf_manifest. Sets P.
pcf_project() {
    local name="$1"; shift
    local gi=1 gicrlf=0 tracked=0 hooks=none dotclaude=0 manifest=1 type=code mopts=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-gitignore) gi=0 ;;
            --gitignore-crlf) gicrlf=1 ;;
            --tracked-tmp) tracked="$2"; shift ;;
            --githooks) hooks=template ;;
            --githooks-noexec) hooks=noexec ;;
            --githooks-custom) hooks=custom ;;
            --dotclaude) dotclaude=1 ;;
            --no-manifest) manifest=0 ;;
            --type) type="$2"; shift ;;
            *) mopts+=("$1") ;;
        esac
        shift
    done
    P="$HOME/$name"
    mkdir -p "$P/.claude" "$P/tmp"
    git -C "$P" init -q -b main
    git -C "$P" config user.email t@t; git -C "$P" config user.name t
    if [ "$manifest" -eq 1 ]; then
        if [ "$dotclaude" -eq 1 ]; then pcf_manifest "$P/.claude/CLAUDE.md" ${mopts[@]+"${mopts[@]}"}
        else pcf_manifest "$P/CLAUDE.md" ${mopts[@]+"${mopts[@]}"}; fi
    fi
    if [ "$gi" -eq 1 ]; then
        printf 'node_modules/\ntmp/\n.claude/.session-lock\n.claude/.session-role.*\ndocs/terminal-logs/\n' > "$P/.gitignore"
        [ "$gicrlf" -eq 1 ] && sed -i 's/$/\r/' "$P/.gitignore"
    fi
    case "$hooks" in
        template) mkdir -p "$P/.githooks"; cp "$PC_TEMPLATE_HOOK" "$P/.githooks/pre-commit"; chmod +x "$P/.githooks/pre-commit" ;;
        noexec)   mkdir -p "$P/.githooks"; cp "$PC_TEMPLATE_HOOK" "$P/.githooks/pre-commit"; chmod -x "$P/.githooks/pre-commit" ;;
        custom)   mkdir -p "$P/.githooks"; printf '#!/usr/bin/env bash\nexit 0\n' > "$P/.githooks/pre-commit"; chmod +x "$P/.githooks/pre-commit" ;;
    esac
    printf '# Backlog — %s\n\n## Open\n\n- [ ] [P2] `FIX-07` **a**: b\n- [ ] [P3] `FIX-12` **c**: d\n\n## Done\n\n- [x] old\n' "$name" > "$P/backlog.md"
    printf 'x\n' > "$P/README.md"
    local i; for i in $(seq 1 "$tracked"); do printf '%s\n' "$i" > "$P/tmp/t$i.txt"; git -C "$P" add -f "tmp/t$i.txt"; done
    git -C "$P" add -A >/dev/null 2>&1
    git -C "$P" commit -qm init >/dev/null 2>&1
    [ -n "${CFG_FIX:-}" ] && pcf_register "$name" "~/$name" "$type"
    return 0
}

# pcf_bare_remote <project-dir> — a local bare origin the project tracks (for commit+push tests)
pcf_bare_remote() {
    local dir="$1" bare
    bare="$TEST_TMPDIR/remotes/$(basename "$dir").git"
    mkdir -p "$(dirname "$bare")"
    git init -q --bare -b main "$bare"
    git -C "$dir" remote add origin "$bare"
    git -C "$dir" push -q -u origin main >/dev/null 2>&1
    printf '%s' "$bare"
}

# pcf_backfill_upstream <project-dir> — model the WSL backfill landing upstream: a second clone of
# the project's origin gets the fixes committed and pushed; the project then FETCHES (no merge),
# so its @{u} knows the backfill commit while HEAD is behind by one. Needs pcf_bare_remote first.
pcf_backfill_upstream() {
    local dir="$1" other
    other="$TEST_TMPDIR/backfill-clone-$(basename "$dir")"
    git clone -q "$(git -C "$dir" remote get-url origin)" "$other" 2>/dev/null || return 1
    git -C "$other" config user.email t@t; git -C "$other" config user.name t
    ( source "$PC_LIB"; pc_fix "$other" "$(basename "$dir")" code >/dev/null )
    git -C "$other" add -A >/dev/null 2>&1
    git -C "$other" commit -qm "Project conformance backfill (CFG-1094)" >/dev/null 2>&1
    git -C "$other" push -q origin main >/dev/null 2>&1
    git -C "$dir" fetch -q origin >/dev/null 2>&1
}

# pcf_lock <project-dir> <pid> [machine] — a session lock file as session-lock.sh writes it
pcf_lock() {
    local machine="${3:-$(hostname 2>/dev/null || uname -n)}"
    mkdir -p "$1/.claude"
    printf '{"machine":"%s","pid":%s,"sessionId":"fx","timestamp":"2026-01-01T00:00:00Z","user":"t","ccSessionId":""}\n' \
        "$machine" "$2" > "$1/.claude/.session-lock"
}

# pcf_sparse_clone <real-dir> <dst> — a local, sparse clone of a REAL project tree: only the
# files the conformance check reads or writes are checked out (fast even for a 300 MB repo).
# rc 1 when the source is not a git repo.
pcf_sparse_clone() {
    local src="$1" dst="$2"
    git -C "$src" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
    git clone -q --local --no-checkout "$src" "$dst" 2>/dev/null || return 1
    git -C "$dst" sparse-checkout set --no-cone /CLAUDE.md /.claude/CLAUDE.md /.gitignore /.githooks/ /backlog.md /tmp/ >/dev/null 2>&1 || return 1
    git -C "$dst" checkout -q 2>/dev/null || return 1
    git -C "$dst" config user.email t@t; git -C "$dst" config user.name t
}

# pcf_run_lib <function> [args…] — call a lib function in a subshell with the seams set
pcf_run_lib() {
    ( # shellcheck disable=SC1090
      source "$PC_LIB"; "$@" )
}
