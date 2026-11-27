#!/usr/bin/env bash
# Tests for setup/scripts/lib-rs-screen.py — CFG-1023 slice 1: render a Claude Code screen from its script(1) log,
# and read a dialog's options (which one the cursor is on, which boxes are ticked) from it.
#
# Every fixture is a REAL Claude Code 2.1.280 capture (MG Q-1023-CAPTURE / -CAPTURE2, 2026-11-27): `*.raw` is the
# script(1) log at that moment (what remote-session reads on WSL), `*.txt` is `tmux capture-pane -p` of the same
# screen (what tmux and Konsole hand over already rendered). The renderer is right when the raw log renders to the
# tmux screen. Findings: docs/research/cfg1023-dialog-captures-2026-11-27.md.
source "$(dirname "$0")/test-helpers.sh"

LIB="$REPO_ROOT/setup/scripts/lib-rs-screen.py"
FX="$REPO_ROOT/setup/tests/fixtures/cfg1023"

suite_header "lib-rs-screen.py (CFG-1023: screen render + dialog options)"

# The non-empty, right-trimmed lines of a screen, in order.
_lines() { sed 's/[[:space:]]*$//' | grep -v '^$'; }

# _renders_to <raw> <txt> — the last N non-empty rendered lines equal the N non-empty lines of the tmux screen.
_renders_to() {
    local want got n
    want=$(_lines < "$FX/$2")
    n=$(printf '%s\n' "$want" | wc -l)
    got=$(python3 "$LIB" render < "$FX/$1" | _lines | tail -n "$n")
    if [[ "$got" != "$want" ]]; then
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -20 >&2
        return 1
    fi
}

t_render_trust()    { _renders_to 01-trust.raw 01-trust.txt; }
t_render_mcp()      { _renders_to 02-mcp.raw 02-mcp.txt; }
t_render_many()     { _renders_to 04-mcp-many.raw 04-mcp-many.txt; }
t_render_imports()  { _renders_to 07-external-imports.raw 07-external-imports.txt; }
run_test "the trust dialog's raw log renders to the tmux screen" t_render_trust
run_test "the MCP-server dialog's raw log renders to the tmux screen" t_render_mcp
run_test "the MCP checklist's raw log renders to the tmux screen" t_render_many
run_test "the external-imports dialog's raw log renders to the tmux screen" t_render_imports

t_render_passes_plain_text() {
    local got
    got=$(python3 "$LIB" render < "$FX/02-mcp.txt" | _lines)
    assert_eq "$(_lines < "$FX/02-mcp.txt")" "$got" "already-rendered text (tmux, Konsole) passes through unchanged"
}
run_test "plain rendered text passes through the renderer unchanged" t_render_passes_plain_text

t_render_tail_of_log() {
    # rs_screen_text hands over only the log's tail on WSL; a tail that starts mid-stream still renders the dialog.
    local got
    got=$(tail -c 1500 "$FX/04-mcp-many.raw" | python3 "$LIB" options)
    assert_contains "$got" "kind=checklist" "a 1500-byte tail still yields the checklist"
}
run_test "a log tail that starts mid-stream still yields the dialog" t_render_tail_of_log

# options: line 1 `kind=<single|checklist> n=<count> cursor=<1-based option, or 'action' for the confirm line>`,
# then one line per option: `<n>\t<1 if the cursor is on it else 0>\t<1 ticked|0 unticked|- no box>\t<text>`.
t_options_trust() {
    local got; got=$(python3 "$LIB" options < "$FX/01-trust.raw")
    assert_eq "kind=single n=2 cursor=1" "$(sed -n 1p <<<"$got")" "header" || return 1
    assert_eq $'1\t1\t-\tNo, exit' "$(sed -n 2p <<<"$got")" "option 1, cursor on it" || return 1
    assert_eq $'2\t0\t-\tYes, I trust this folder' "$(sed -n 3p <<<"$got")" "option 2"
}
run_test "trust dialog: two options, cursor on 'No, exit'" t_options_trust

t_options_mcp() {
    local got; got=$(python3 "$LIB" options < "$FX/02-mcp.raw")
    assert_eq "kind=single n=3 cursor=3" "$(sed -n 1p <<<"$got")" "header: the default is the LAST option" || return 1
    assert_eq $'2\t0\t-\tUse this and all future MCP servers in this project' "$(sed -n 3p <<<"$got")" "option 2" || return 1
    assert_eq $'3\t1\t-\tContinue without using this MCP server' "$(sed -n 4p <<<"$got")" "option 3, cursor on it"
}
run_test "MCP-server dialog: three options, cursor on the last ('Continue without')" t_options_mcp

t_options_checklist() {
    local got; got=$(python3 "$LIB" options < "$FX/04-mcp-many.raw")
    assert_eq "kind=checklist n=3 cursor=1" "$(sed -n 1p <<<"$got")" "header" || return 1
    assert_eq $'1\t1\t1\tdummy-a' "$(sed -n 2p <<<"$got")" "item 1 ticked, cursor on it" || return 1
    assert_eq $'3\t0\t1\tdummy-c' "$(sed -n 4p <<<"$got")" "item 3 ticked"
}
run_test "MCP checklist: three items, all ticked, cursor on the first" t_options_checklist

t_options_checklist_after_space() {
    local got; got=$(python3 "$LIB" options < "$FX/05-mcp-many-moved-unticked.txt")
    assert_eq "kind=checklist n=3 cursor=2" "$(sed -n 1p <<<"$got")" "cursor moved to item 2" || return 1
    assert_eq $'2\t1\t0\tdummy-b' "$(sed -n 3p <<<"$got")" "item 2 unticked by Space"
}
run_test "MCP checklist after Down + Space: cursor on item 2, item 2 unticked" t_options_checklist_after_space

t_options_checklist_on_action() {
    local got; got=$(python3 "$LIB" options < "$FX/06-mcp-many-on-enable.txt")
    assert_eq "kind=checklist n=3 cursor=action" "$(sed -n 1p <<<"$got")" "cursor on 'Enable selected'"
}
run_test "MCP checklist with the cursor on 'Enable selected'" t_options_checklist_on_action

t_options_imports() {
    local got; got=$(python3 "$LIB" options < "$FX/07-external-imports.raw")
    assert_eq "kind=single n=2 cursor=1" "$(sed -n 1p <<<"$got")" "header" || return 1
    assert_eq $'1\t1\t-\tNo, disable external imports' "$(sed -n 2p <<<"$got")" "the default is 'No'"
}
run_test "external-imports dialog: cursor on 'No, disable external imports'" t_options_imports

t_options_none_at_prompt() {
    local rc=0
    printf 'Claude Code v2.1.280\n❯ \n  ? for shortcuts\n' | python3 "$LIB" options >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "no dialog on screen → exit 1"
}
run_test "a prompt screen has no dialog options (exit 1)" t_options_none_at_prompt

suite_summary
