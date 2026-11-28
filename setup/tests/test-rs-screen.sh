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

t_options_checklist_glyph_in_name() {
    # Review finding 4: a server named with `❯` (a third party's .mcp.json) was a second cursor. Only the marker in
    # front of the box is the cursor; only a line STARTING with it is the action line. Synthetic from 04.
    local got
    got=$(sed 's/dummy-b$/dummy❯b/; s/dummy-c$/❯dummy-c/' "$FX/04-mcp-many.txt" | python3 "$LIB" options)
    assert_eq "kind=checklist n=3 cursor=1" "$(sed -n 1p <<<"$got")" "the cursor stays on item 1" || return 1
    assert_eq $'2\t0\t1\tdummy❯b' "$(sed -n 3p <<<"$got")" "a ❯ inside a name is text, not the cursor" || return 1
    assert_eq $'3\t0\t1\t❯dummy-c' "$(sed -n 4p <<<"$got")" "nor at its start, behind the box"
}
run_test "MCP checklist: a ❯ in a server's name is not the cursor" t_options_checklist_glyph_in_name

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

# ── AskUserQuestion (slice 2, fixtures 08–15, captured with AFK off 2026-11-27) ──────────────────────────────────
# The layout differs from the approval dialogs: a tab row `←  ☐ Single  ☐ Multi  ✔ Submit  →`, the question,
# NUMBERED options each followed by an indented description line, `Type something` (the automatic Other), a rule,
# `Chat about this`; multiSelect items carry `[ ]`/`[✔]` and end with a `Submit` line; the review page has no guide.
# Slice 1 read 08 as `kind=single n=1` — a wrong answer. The option number printed is the one on screen.

t_render_ask() { _renders_to 08-ask-single.raw 08-ask-single.txt && _renders_to 09-ask-multi.raw 09-ask-multi.txt; }
run_test "the AskUserQuestion raw logs render to the tmux screen" t_render_ask

t_options_ask_single() {
    local got; got=$(python3 "$LIB" options < "$FX/08-ask-single.raw")
    assert_eq "kind=ask-single n=5 cursor=1" "$(sed -n 1p <<<"$got")" "header: description lines are not options" || return 1
    assert_eq $'1\t1\t-\tAlpha' "$(sed -n 2p <<<"$got")" "option 1, cursor on it" || return 1
    assert_eq $'2\t0\t-\tBeta' "$(sed -n 3p <<<"$got")" "option 2" || return 1
    assert_eq $'4\t0\t-\tType something.' "$(sed -n 5p <<<"$got")" "option 4 is the automatic Other" || return 1
    assert_eq $'5\t0\t-\tChat about this' "$(sed -n 6p <<<"$got")" "option 5 below the rule"
}
run_test "AskUserQuestion single-select: five numbered options, cursor on 1" t_options_ask_single

t_options_ask_multi() {
    local got; got=$(python3 "$LIB" options < "$FX/09-ask-multi.raw")
    assert_eq "kind=ask-multi n=5 cursor=1" "$(sed -n 1p <<<"$got")" "header" || return 1
    assert_eq $'1\t1\t0\tRed' "$(sed -n 2p <<<"$got")" "boxes start unticked" || return 1
    assert_eq $'4\t0\t0\tType something' "$(sed -n 5p <<<"$got")" "Other has a box" || return 1
    assert_eq $'5\t0\t-\tChat about this' "$(sed -n 6p <<<"$got")" "Chat about this has none"
}
run_test "AskUserQuestion multiSelect: four boxes unticked plus 'Chat about this'" t_options_ask_multi

t_options_ask_multi_ticked() {
    local got; got=$(python3 "$LIB" options < "$FX/10-ask-multi-1-3.txt")
    assert_eq $'1\t1\t1\tRed' "$(sed -n 2p <<<"$got")" "1 ticked" || return 1
    assert_eq $'2\t0\t0\tGreen' "$(sed -n 3p <<<"$got")" "2 not" || return 1
    assert_eq $'3\t0\t1\tBlue' "$(sed -n 4p <<<"$got")" "3 ticked"
}
run_test "AskUserQuestion multiSelect after keys 1 and 3: Red and Blue ticked" t_options_ask_multi_ticked

t_options_ask_other_typed() {
    local got; got=$(python3 "$LIB" options < "$FX/12-ask-multi-on-other.txt")
    assert_eq "kind=ask-multi n=5 cursor=4" "$(sed -n 1p <<<"$got")" "cursor on Other (guide gains 'ctrl+g')" || return 1
    got=$(python3 "$LIB" options < "$FX/13-ask-multi-other-typed.txt")
    assert_eq $'4\t1\t1\thello world' "$(sed -n 5p <<<"$got")" "typed text replaces 'Type something' in place"
}
run_test "AskUserQuestion Other: cursor on 4, then the typed text shows as option 4" t_options_ask_other_typed

t_options_ask_on_submit() {
    # No capture has the cursor on `Submit`; this screen is 10's with the ❯ moved there (the review page, 14, is real).
    local got; got=$(sed -e 's/^❯ 1\. \[✔\] Red/  1. [✔] Red/' -e 's/^     Submit$/   ❯ Submit/' "$FX/10-ask-multi-1-3.txt" \
        | python3 "$LIB" options)
    assert_eq "kind=ask-multi n=5 cursor=action" "$(sed -n 1p <<<"$got")" "cursor on the Submit line"
}
run_test "AskUserQuestion multiSelect with the cursor on 'Submit' reads cursor=action" t_options_ask_on_submit

t_options_ask_review() {
    local got; got=$(python3 "$LIB" options < "$FX/14-ask-review.raw")
    assert_eq "kind=ask-review n=2 cursor=1" "$(sed -n 1p <<<"$got")" "the review page has no guide line" || return 1
    assert_eq $'1\t1\t-\tSubmit answers' "$(sed -n 2p <<<"$got")" "option 1" || return 1
    assert_eq $'2\t0\t-\tCancel' "$(sed -n 3p <<<"$got")" "option 2"
}
run_test "AskUserQuestion review page: 'Submit answers' / 'Cancel'" t_options_ask_review

t_options_ask_answered() {
    local rc=0
    python3 "$LIB" options < "$FX/15-ask-submitted.txt" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "an answered question in the history is not a dialog"
}
run_test "after submitting, the answered question is history, not a dialog (exit 1)" t_options_ask_answered

t_options_ask_one_question_refused() {
    # SYNTHETIC (Fable review 2026-11-27, finding 1): a ONE-question single-select AskUserQuestion draws no ←/→ tab row
    # (CC 2.1.280 hideSubmitTab), only `☐ Header`; no real capture yet. 08's screen with its tab row cut down to that.
    # Read as an approval dialog it was `single n=1` — answer-dialog then pressed Enter on it. It must be refused.
    local rc=0 got
    got=$(sed 's/^←  ☐ Single  ☐ Multi  ✔ Submit  →$/☐ Single/; s|Tab/Arrow keys to navigate|↑/↓ to navigate|' \
          "$FX/08-ask-single.txt" | python3 "$LIB" options 2>&1) || rc=$?   # the one-question footer (binary)
    assert_eq "1" "$rc" "an 'Enter to select' screen the AskUserQuestion parse cannot read is refused, never read as an approval dialog (got: $got)"
}
run_test "a one-question AskUserQuestion (no tab row) is refused, not misread as an approval dialog" t_options_ask_one_question_refused

t_options_numbered_not_single() {
    # Review finding 1(b): no approval dialog numbers its options (01, 02, 07); AskUserQuestion and Claude Code's own
    # pickers do. A numbered run is listed as `numbered` — readable for `dialog`, never an answerable `single`.
    local got
    got=$(printf '  Choose the text style\n  ❯ 1. Dark mode\n    2. Light mode\n  Enter to confirm · Esc to cancel\n' | python3 "$LIB" options)
    assert_eq "kind=numbered n=2 cursor=1" "$(sed -n 1p <<<"$got")" "a numbered option run is not kind=single" || return 1
    assert_eq $'2\t0\t-\t2. Light mode' "$(sed -n 3p <<<"$got")" "the entries are still read, as drawn"
}
run_test "a numbered option run reads as kind=numbered, never as an approval dialog's single" t_options_numbered_not_single

t_options_empty_cursor_line() {
    # Re-review NIT 5: a `❯` with nothing after it (an empty prompt) above a guide raised AttributeError — a traceback
    # must never stand for "unreadable". Clean exit 1, no traceback.
    local rc=0 err
    err=$(printf '❯\nEnter to confirm · Esc to cancel\n' | python3 "$LIB" options 2>&1 >/dev/null) || rc=$?
    assert_eq "1" "$rc" "no dialog read" || return 1
    assert_not_contains "$err" "Traceback" "and no traceback"
}
run_test "an empty ❯ line above a guide reads as no dialog, without a traceback" t_options_empty_cursor_line

suite_summary
