#!/usr/bin/env bash
# remote-session-submit-lib.sh — SUBMIT one line into another Claude Code session (CFG-1006).
# Sourced by remote-session-lib.sh, whose resolve / dispatch / transcript helpers it uses; not run.
#
# Typed is not sent. Claude Code 2.1.280 acts on a control byte — an Enter, a clearing key — ONLY when it
# arrives in a read of fewer than 64 bytes; a read of 64+ bytes is ONE text token whose control bytes do
# nothing (its input tokenizer, bin/claude.exe offset 191421218). Measured: a 330-byte order and its
# Enter arrived as one read, the Enter became text and the order sat unsent in the target session while
# the driver reported done. So a prompt's text and its Enter are separate writes RS_KEY_GAP apart, every
# write that holds a control byte is a few bytes, and success is read from the transcript.
#
# Whatever sits in the input box when Enter lands goes out WITH the text as one prompt — and runs. So
# the input line is cleared before the text is typed and again whenever we give up: Ctrl+K (delete to
# line end) then Ctrl+U (delete to line start), each × RS_CLEAR_PRESSES, in writes of at most
# RS_CLEAR_BATCH keys RS_CLEAR_GAP apart on every path (tty-inject.py --clear writes the same way) — sent
# as one burst, 128 such bytes were read as [21,107] and no Ctrl+U acted. Each press removes ONE line's
# text or ONE newline (Claude Code 2.1.280), so the default 64 — tty-inject.py's maximum — empties a
# multi-line (Shift+Enter) draft of about 30 lines on either side of the cursor; a taller one leaves
# lines, and a prompt holding our text as one line among others is reported merged (rs_prompt_state).
# These two keys are safe in every state of a session (2.1.280 default keybindings): Ctrl+K has no
# binding outside the input box and Ctrl+U only scrolls (scroll:halfPageUp) the Settings and Transcript
# views — while Esc interrupts a running turn and declines a permission prompt, Esc Esc on an empty box
# opens the rewind menu, Ctrl+C interrupts or, on an empty box, arms exit, and Ctrl+E (end of line) is
# the docs' own example of a key users rebind. What they delete goes to Claude Code's kill ring: Ctrl+Y
# pastes the NEWEST kill and Alt+Y right after it cycles to older ones. After a give-up the newest kill
# is OUR cleared order, so a human recovering a draft presses Ctrl+Y then Alt+Y — and never sends what
# Ctrl+Y alone brings back. No key at all goes in while the session shows a dialog (record status
# "waiting": its selector acts on single keys), and the status is read again right before the text and
# right before each Enter — a dialog can come up during the clear or a key gap. The input target is
# resolved once, BEFORE those reads (rs_input_target), so each read is followed directly by its key.
#
# A session with NO transcript yet — brand-new, or just /clear-ed — writes its file with its first PROCESSED
# prompt, and that comes only once its SessionStart hooks have run: ~100 s on this fleet (measured
# 2026-11-19, CFG-1043 data point 1: `startup` typed right after /clear was taken and queued, no file showed
# for 24 s, and the driver pressed two more Enters and a clear into the live session, then reported "NOT
# submitted"). So after the first Enter into such a session the file is WAITED for (RS_SUBMIT_FIRST_WAIT,
# default 300 s) — no further Enter, and no clearing keys at the give-up, since the line may already be in.
# Overridable for tests: RS_CLEAR_PRESSES, RS_CLEAR_BATCH, RS_CLEAR_GAP, RS_DIALOG_WAIT (seconds a give-up
# waits for a dialog to close before it may clear the line), RS_SUBMIT_FIRST_WAIT.

RS_CLEAR_PRESSES="${RS_CLEAR_PRESSES:-64}"
RS_CLEAR_BATCH="${RS_CLEAR_BATCH:-8}"   # clearing keys per write (tty-inject.py: CLEAR_BATCH)
RS_CLEAR_GAP="${RS_CLEAR_GAP:-0.1}"     # seconds between two writes of the clear (tty-inject.py: KEY_GAP)
RS_DIALOG_WAIT="${RS_DIALOG_WAIT:-60}"
RS_SUBMIT_FIRST_WAIT="${RS_SUBMIT_FIRST_WAIT:-300}"   # seconds a session with no transcript gets to write one
RS_SUBMIT_STATE=""     # set by rs_submit_line / rs_wait_submitted: submitted | queued | merged | none
RS_SUBMIT_TARGET=none  # set by rs_submit_refusal: rs_input_target of the pid being submitted to
RS_SUBMIT_NOTRANSCRIPT=0   # set by rs_submit_first_wait: the line could be in, nothing more is pressed or cleared

# rs_dialog_up <pid> — 0 while the session's own record says status "waiting" (a dialog is up)
rs_dialog_up() { [[ "$(rs_session_field "$1" status "$(rs_cc_dir_of "$1")")" == waiting ]]; }

# rs_clear_input <pid> [target] — empty the target's input line: Ctrl+K × RS_CLEAR_PRESSES, then Ctrl+U ×
# the same, in writes of at most RS_CLEAR_BATCH keys RS_CLEAR_GAP apart (tmux key names / Konsole sendText;
# WSL: tty-inject.py --clear N, which writes the same way). [target]: rs_input_target's answer, resolved
# here when absent. 3 when there is no input target. Never call it while rs_dialog_up: a selector would
# get the keys.
rs_clear_input() {
    rs_gate_armed "$1" || return 3   # CFG-1083 F1: a clearing key is a key
    local t keys first=1; t="${2:-$(rs_input_target "$1")}"; set -- "$1" $t
    case "$2" in
        wsl) $RS_INJECT "$RS_INJECTOR" --expect-pid "$1" --clear "$RS_CLEAR_PRESSES" --no-cr "$3"; return ;;
        tmux|konsole) ;;
        *) return 3 ;;
    esac
    while read -r -a keys; do
        (( first )) || sleep "$RS_CLEAR_GAP"; first=0
        rs_alive "$1" || return 3   # a pre-resolved pane/tab outlives its claude
        if [[ "$2" == tmux ]]; then "$RS_TMUX" send-keys -t "$3" "${keys[@]}" || return
        else "$RS_QDBUS" "$3" "$4" org.kde.konsole.Session.sendText "$(rs_key_bytes "${keys[@]}")" >/dev/null || return; fi
    done < <(rs_clear_batches)
}

# rs_clear_batches — the clear's writes, one line each: at most RS_CLEAR_BATCH tmux key names, the
# RS_CLEAR_PRESSES × C-k first, then as many C-u
rs_clear_batches() {
    local i n="$RS_CLEAR_PRESSES" line=()
    for (( i = 0; i < 2 * n; i++ )); do
        if (( i < n )); then line+=(C-k); else line+=(C-u); fi
        (( ${#line[@]} >= RS_CLEAR_BATCH )) && { echo "${line[*]}"; line=(); }
    done
    (( ${#line[@]} )) && echo "${line[*]}"
    return 0
}

# rs_key_bytes <key name>... — the bytes Konsole's sendText needs for C-k / C-u
rs_key_bytes() { local k s=""; for k; do if [[ "$k" == C-k ]]; then s+=$'\x0b'; else s+=$'\x15'; fi; done; printf '%s' "$s"; }

# rs_prompt_state <transcript> <offset> <text> — echo what the transcript records of <text> after byte
# <offset>. "submitted": a user prompt (a string or text blocks; not isMeta, not a tool result) that IS
# the text (whitespace-trimmed), or holds it as one whole line once an enqueue of exactly the text was
# seen (a busy session sends its queued prompts as one, a line each); a /command counts by its
# <command-name>. "queued": CC's queue-operation "enqueue" of exactly the text (a busy session queues the
# prompt and writes the user message when its turn ends) not withdrawn by a later "popAll" (the queue
# pulled back into the input box). "merged": a prompt or enqueue holding the text with more — a longer
# line that starts or ends with it, or other lines around it that no enqueue of ours explains: what sat
# in the input box went out with it ("yes" sent, "yesterday's report" recorded is merged too: never
# confirmed). "none" otherwise, and without a transcript. Lines before <offset> never count.
rs_prompt_state() {
    [[ -f "$1" ]] || { echo none; return 0; }
    tail -c +"$(( $2 + 1 ))" "$1" 2>/dev/null | python3 -c 'import json,sys
want = sys.argv[1].strip()
cmd = "<command-name>%s</command-name>" % want.split()[0] if want.startswith("/") else None
def exact(t):
    return isinstance(t, str) and (t.strip() == want or bool(cmd and cmd in t))
def a_line(t):
    return isinstance(t, str) and any(l.strip() == want for l in t.splitlines())
def mixed(t):
    if not isinstance(t, str): return False
    return any(l.strip() != want and (l.strip().startswith(want) or l.strip().endswith(want)) for l in t.splitlines())
def texts(d):
    if d.get("type") != "user" or d.get("isMeta"): return []
    c = (d.get("message") or {}).get("content")
    if isinstance(c, str): return [c]
    if not isinstance(c, list): return []
    blocks = [b for b in c if isinstance(b, dict)]
    if any(b.get("type") == "tool_result" for b in blocks): return []
    return [b.get("text") for b in blocks if b.get("type") == "text"]
queued = merged = False
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if not isinstance(d, dict): continue
    if d.get("type") == "queue-operation":
        op, c = d.get("operation"), d.get("content")
        if op == "enqueue" and exact(c): queued = True
        elif op == "enqueue" and (a_line(c) or mixed(c)): merged = True
        elif op == "popAll": queued = False
        continue
    ts = texts(d)
    if any(exact(t) or (queued and a_line(t)) for t in ts): print("submitted"); sys.exit(0)
    if any(a_line(t) or mixed(t) for t in ts): merged = True
print("queued" if queued else "merged" if merged else "none")' "$3"
}

# rs_prompt_submitted <transcript> <offset> <text> — 0 when rs_prompt_state is submitted or queued
rs_prompt_submitted() { case "$(rs_prompt_state "$@")" in submitted|queued) return 0 ;; esac; return 1; }

# rs_wait_submitted <pid> <text> <base-transcript> <base-offset> <seconds> — poll rs_prompt_state into
# RS_SUBMIT_STATE: 0 submitted or queued, 2 merged (that prompt is out: stop), 1 neither within
# <seconds> (0 = one read). The transcript is re-resolved every poll: a NEW session (or one just
# /clear-ed) creates its file with the first prompt, so a file other than the base one is read from 0.
rs_wait_submitted() {
    local end=$(( SECONDS + $5 )) tr off
    while :; do
        if tr=$(rs_transcript_of "$1"); then
            off=0; [[ "$tr" == "$3" ]] && off="$4"
            RS_SUBMIT_STATE=$(rs_prompt_state "$tr" "$off" "$2")
            case "$RS_SUBMIT_STATE" in submitted|queued) return 0 ;; merged) return 2 ;; esac
        fi
        (( SECONDS >= end )) && return 1
        sleep "$RS_POLL"
    done
}

# rs_submit_line <pid> <text> — submit ONE line: refused while a dialog is up; the input line cleared,
# the text typed, RS_KEY_GAP, Enter as a SEPARATE keystroke (twice more if the transcript does not record
# it), and a clean give-up. 0 confirmed: RS_SUBMIT_STATE "submitted" (a user prompt) or "queued" (a busy
# session holds it — not run yet), RS_SUBMIT_TRIES = Enter presses. 2 blank or multi-line text (a control
# character would act as a keystroke on the tmux/Konsole paths). 3 the text not typed (a dialog is up —
# before the clear or once it ran —, no input target, or the line could not be cleared first). 4 typed
# but NOT submitted as sent — and our text is not left in the input box (rs_submit_giveup). Every failure
# sets RS_REASON and prints it to stderr; a 4 says to read the target's transcript before any resend.
rs_submit_line() {
    local pid="$1" text="$2" base="" boff=0 rc
    RS_REASON="" RS_SUBMIT_TRIES=0 RS_SUBMIT_STATE=none RS_SUBMIT_TARGET=none RS_SUBMIT_NOTRANSCRIPT=0
    base=$(rs_transcript_of "$pid") && boff=$(stat -c %s "$base" 2>/dev/null || echo 0)   # read-only, before the guard
    rs_submit_refusal "$pid" "$text"; rc=$?
    (( rc == 0 )) && { rs_submit_type "$pid" "$text" "$RS_SUBMIT_TARGET" || rc=3; }
    if (( rc == 0 )); then
        rs_submit_enter "$pid" "$text" "$base" "$boff" "$RS_SUBMIT_TARGET" && return 0
        # no transcript to judge by: the line may be in, so nothing is cleared (rs_submit_first_wait)
        (( RS_SUBMIT_NOTRANSCRIPT )) || { rs_submit_giveup "$pid" "$text" "$base" "$boff" "$RS_SUBMIT_TARGET" && return 0; }
        rc=4
    fi
    echo "remote-session: $RS_REASON" >&2
    return "$rc"
}

# rs_submit_refusal <pid> <text> — 0 when <text> may be typed into <pid> now; else RS_REASON and 2
# (blank or multi-line text) or 3 (a dialog is up). Nothing is typed either way. A text that may be typed
# has its input target resolved into RS_SUBMIT_TARGET BEFORE the dialog guard is read (rs_input_target).
rs_submit_refusal() {
    if [[ -z "${2//[[:space:]]/}" ]]; then RS_REASON="nothing to submit (blank text) — nothing typed"; return 2; fi
    if [[ "$2" == *[[:cntrl:]]* ]]; then
        RS_REASON="refused: the text contains a control character (a prompt is one line) — nothing typed"; return 2
    fi
    RS_SUBMIT_TARGET=$(rs_input_target "$1")
    rs_dialog_up "$1" || return 0
    RS_REASON="refused: pid $1 shows a dialog (record status waiting), whose selector acts on single keys — nothing typed"
    return 3
}

# rs_submit_type <pid> <text> [target] — clear the input line, then type the text (no Enter), each followed
# by RS_KEY_GAP so no write joins the next one in a read. The dialog guard is read again right before the
# text: one that came up during the clear or the gap gets no character of it. [target]: rs_input_target,
# resolved by the caller before its first guard read. 1 + RS_REASON when the text is not typed (that
# dialog, or a key that cannot be delivered; a partly typed text is cleared again).
rs_submit_type() {
    local rc
    rs_clear_input "$1" "${3:-}"; rc=$?
    if (( rc )); then
        RS_REASON="could not clear the input line of pid $1 (rc $rc: no input target, or the injector refused) — nothing typed"
        return 1
    fi
    sleep "$RS_KEY_GAP"
    if rs_dialog_up "$1"; then
        RS_REASON="refused: pid $1 showed a dialog (record status waiting) once its input line was cleared, and its selector acts on single keys — the text was NOT typed"
        return 1
    fi
    rs_type_text "$1" "$2" "${3:-}"; rc=$?
    if (( rc )); then
        RS_REASON="could not type into pid $1 (rc $rc: no input target, or the injector refused) — nothing submitted; $(rs_submit_clear_note "$1" "${3:-}")"
        return 1
    fi
    sleep "$RS_KEY_GAP"
}

# rs_submit_enter <pid> <text> <base> <boff> [target] — Enter as a separate keystroke, up to three times,
# each followed by RS_SUBMIT_WAIT seconds of reading the transcript. 0 confirmed (RS_SUBMIT_STATE submitted
# or queued); 1 + RS_REASON otherwise. Never pressed into a dialog that came up after the text; not retried
# once the text went out merged, nor when Enter cannot be delivered, nor while the session has NO transcript
# at all (its file comes with its first processed prompt: rs_submit_first_wait waits for it instead).
rs_submit_enter() {
    local try rc
    for try in 1 2 3; do
        if rs_dialog_up "$1"; then
            RS_REASON="typed but NOT submitted into pid $1: a dialog came up after the text was typed (status waiting), Enter not pressed"
            return 1
        fi
        rs_press_enter "$1" "${5:-}" || { RS_REASON="typed but NOT submitted into pid $1: Enter could not be delivered"; return 1; }
        RS_SUBMIT_TRIES=$try
        rs_wait_submitted "$1" "$2" "$3" "$4" "$RS_SUBMIT_WAIT"; rc=$?
        (( rc == 0 )) && return 0
        (( rc == 2 )) && { RS_REASON=$(rs_merged_why "$1"); return 1; }
        rs_transcript_of "$1" >/dev/null 2>&1 || { rs_submit_first_wait "$1" "$2" "$3" "$4"; return; }
        RS_REASON="typed but NOT submitted into pid $1: no user prompt equal to the text, and no queued one, in its transcript after $try Enter press(es)"
    done
    return 1
}

# rs_submit_first_wait <pid> <text> <base> <boff> — the session has no transcript (new, or just /clear-ed:
# the file comes with its first processed prompt, after its SessionStart hooks — CFG-1043 data point 1).
# Wait up to RS_SUBMIT_FIRST_WAIT for it, pressing nothing. 0 confirmed; 1 + RS_REASON otherwise, with
# RS_SUBMIT_NOTRANSCRIPT=1: the Enter may have been taken, so the caller presses and clears nothing more.
rs_submit_first_wait() {
    local rc sid
    rs_wait_submitted "$1" "$2" "$3" "$4" "$RS_SUBMIT_FIRST_WAIT"; rc=$?
    (( rc == 0 )) && return 0
    RS_SUBMIT_NOTRANSCRIPT=1
    (( rc == 2 )) && { RS_REASON=$(rs_merged_why "$1"); return 1; }
    sid=$(rs_session_field "$1" sessionId "$(rs_cc_dir_of "$1")")
    if rs_transcript_of "$1" >/dev/null 2>&1; then
        RS_REASON="typed and entered into pid $1, but its transcript (session ${sid:-?}), which appeared only now, does not record the line — Enter NOT pressed again and the input line NOT cleared; read that transcript before any resend"
    else
        RS_REASON="typed and entered into pid $1, but no transcript appeared for its session ${sid:-?} within ${RS_SUBMIT_FIRST_WAIT}s (a new or just-/clear-ed session writes it with its first processed prompt, after its SessionStart hooks) — the line may have been submitted: Enter NOT pressed again and the input line NOT cleared; read its transcript before any resend"
    fi
    return 1
}

rs_merged_why() {
    echo "MERGED, not submitted as sent: pid $1's transcript holds a prompt with the text inside a longer line — what sat in its input box went out with it, and that prompt has run (or is queued)"
}

# rs_submit_clear_note <pid> [target] — clear the input line; echo what that did, for a failure report;
# 1 not cleared. A cleared line takes its typing stamp with it (rs_unstamp: the shutdown-follow hook
# would otherwise eat the user's next real `cls`).
rs_submit_clear_note() {
    if rs_clear_input "$1" "${2:-}" >/dev/null 2>&1; then
        rs_unstamp "$1"
        echo "our text was cleared from its input line (Ctrl+K, Ctrl+U, a few keys per write)"; return 0
    fi
    echo "our text could NOT be cleared from its input line — clear it there by hand (Ctrl+U)"; return 1
}

# rs_giveup_clear <pid> [target] — our text may sit in <pid>'s input box, where the next Enter (anyone's)
# would send it, merged with whatever is typed next. Wait for a dialog to close (up to RS_DIALOG_WAIT: the
# clearing keys must not reach a selector), then clear the line. The target is resolved (when not given)
# BEFORE the guard is read, so the last read and the clear are one step apart. Echo what happened, for a
# report: 0 cleared, 1 the clear failed, 2 the dialog stayed up (nothing pressed).
rs_giveup_clear() {
    local end=$(( SECONDS + RS_DIALOG_WAIT )) t="${2:-$(rs_input_target "$1")}"
    while rs_dialog_up "$1"; do
        if (( SECONDS >= end )); then
            echo "our text is STILL in its input box behind the dialog (status waiting for ${RS_DIALOG_WAIT}s) — clear it there (Ctrl+U) before anyone presses Enter"
            return 2
        fi
        sleep "$RS_POLL"
    done
    rs_submit_clear_note "$1" "$t"
}

# rs_submit_giveup <pid> <text> <base> <boff> [target] — we stop, and our text must not stay in the input
# box: rs_giveup_clear, then read the transcript once more — an Enter can land late. 0 when the prompt was
# submitted or queued after all; else 1 with RS_REASON saying what happened and to read the transcript
# before any resend.
rs_submit_giveup() {
    local why="$RS_REASON" tr cleared rc
    tr=$(rs_transcript_of "$1") || tr="none found"
    cleared=$(rs_giveup_clear "$1" "${5:-}"); rc=$?
    if (( rc == 2 )); then
        RS_REASON="$why; $cleared, and read its transcript ($tr) before sending again"
        return 1
    fi
    sleep "$RS_KEY_GAP"
    rs_wait_submitted "$1" "$2" "$3" "$4" 0; rc=$?
    (( rc == 0 )) && { RS_REASON=""; return 0; }
    (( rc == 2 )) && why=$(rs_merged_why "$1")
    RS_REASON="$why; $cleared. Read its transcript ($tr) before sending again — never resend blind"
    return 1
}
