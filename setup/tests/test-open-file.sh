#!/usr/bin/env bash
# test-open-file.sh — contract tests for setup/scripts/open-file.sh (CFG-560)
#
# The association table is the part that is testable without a GUI, so that is what
# this asserts. Every case runs with OPEN_FILE_DRY=1, which resolves the target
# application and prints the decision instead of launching anything — so the suite
# never spawns a browser on a developer's desktop and never hangs a CI box.
#
# OPEN_FILE_MACHINE overrides machine detection so one box can assert every machine's
# rows. Without it the script detects the real machine, which is what production does.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/setup/scripts/open-file.sh"

PASSED=0; FAILED=0; FAILURES=()
pass() { PASSED=$((PASSED + 1)); echo "  PASS $1"; }
fail() { FAILED=$((FAILED + 1)); FAILURES+=("$1"); echo "  FAIL $1"; }

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

echo "=== open-file.sh: the association table ==="

[ -f "$HELPER" ] || { echo "  FAIL open-file.sh does not exist"; exit 1; }

# Every probe needs a real file — "does the file exist" is checked before dispatch,
# and a test that passes a nonexistent path would assert the wrong branch.
_mk() { local f="$_tmp/$1"; : > "$f"; printf '%s' "$f"; }

# _decide <machine> <filename> → the resolved application token on stdout
_decide() {
    OPEN_FILE_DRY=1 OPEN_FILE_MACHINE="$1" bash "$HELPER" "$(_mk "$2")" 2>/dev/null
}

# ── WSL rows, exactly as MG approved them 2026-09-10 ────────────────────────
# png/jpg/jpeg/gif/webp/svg/pdf/html → Chrome; txt/md/log → Notepad; else → VS Code.
_wsl_chrome_ok=1
for _ext in png jpg jpeg gif webp svg pdf html; do
    if ! _decide wsl "sample.$_ext" | grep -qi 'chrome'; then
        _wsl_chrome_ok=0
        fail "WSL .$_ext should open in Chrome"
    fi
done
[ "$_wsl_chrome_ok" -eq 1 ] && pass "WSL: images, PDF and HTML all route to Chrome"

_wsl_notepad_ok=1
for _ext in txt md log; do
    if ! _decide wsl "sample.$_ext" | grep -qi 'notepad'; then
        _wsl_notepad_ok=0
        fail "WSL .$_ext should open in Notepad"
    fi
done
[ "$_wsl_notepad_ok" -eq 1 ] && pass "WSL: txt, md and log route to Notepad"

# ── VS Code is retired, fleet-wide ─────────────────────────────────────────
# MG 2026-09-10: "yes, no more vs code", reaffirming the 2026-08-25 fleet-wide ruling.
# This asserts the retirement itself, so a future edit that reintroduces a `code` row
# goes red instead of quietly restoring a tool he has now removed twice.
if ! grep -vE '^[[:space:]]*#' "$HELPER" | grep -qE "\bcode\b"; then
    pass "WSL: no VS Code row survives anywhere in the executable code"
else
    fail "WSL: a VS Code reference is still live in open-file.sh"
fi

# ── The catch-all is a SPLIT, not a rename ─────────────────────────────────
# Routing every unmapped extension to Notepad would open .docx/.xlsx/.zip as binary
# garbage. Text-shaped files keep the convenience; binary ones degrade to the path.
_wsl_source_ok=1
for _ext in py sh json yml csv ts sql css; do
    if ! _decide wsl "sample.$_ext" | grep -qi 'notepad'; then
        _wsl_source_ok=0
        fail "WSL: source/config extension .$_ext did not route to Notepad"
        break
    fi
done
[ "$_wsl_source_ok" -eq 1 ] && pass "WSL: source and config extensions route to Notepad"

_wsl_binary_ok=1
for _ext in docx xlsx zip exe bin pptx; do
    if _decide wsl "sample.$_ext" | grep -qi 'notepad'; then
        _wsl_binary_ok=0
        fail "WSL: binary extension .$_ext was routed to Notepad — that renders as garbage"
        break
    fi
done
[ "$_wsl_binary_ok" -eq 1 ] && pass "WSL: binary extensions are NOT routed to Notepad"

# An unmapped extension must still RESOLVE — printing the path is a real outcome, an
# error is not. If the fallback errored, "open every file you produce" would quietly
# stop applying to anything unusual, which is most of what a session produces.
if _decide wsl "Makefile" >/dev/null 2>&1; then
    pass "WSL: a file with no extension at all still resolves"
else
    fail "WSL: a file with no extension did not resolve"
fi

# ── Extension matching is case-insensitive ─────────────────────────────────
# Cameras and scanners emit .JPG and .PNG constantly; a case-sensitive table sends
# every one of them to the editor, which is the wrong app and looks like a bug.
if _decide wsl "PHOTO.JPG" | grep -qi 'chrome'; then
    pass "extension matching is case-insensitive"
else
    fail ".JPG did not match the .jpg row"
fi

echo "=== headless machines degrade honestly ==="

# ── A machine with no GUI must say so, not pretend ─────────────────────────
# MG's wording: degrade to printing the path WITH A STATED REASON. A silent no-op
# would be worse than the path-reporting this whole rule exists to replace, because
# the session would believe it had shown him something.
_headless_ok=1
for _m in headless some-server-class; do
    _out="$(_decide "$_m" "sample.png")"
    if ! printf '%s' "$_out" | grep -qi 'path-only\|no gui\|headless'; then
        _headless_ok=0
        fail "$_m should degrade to path-only with a reason, got: $_out"
    fi
    if ! printf '%s' "$_out" | grep -q "$_tmp"; then
        _headless_ok=0
        fail "$_m degraded but did not print the path itself"
    fi
done
[ "$_headless_ok" -eq 1 ] && pass "headless machines print the path and say why"

# ── An unknown machine degrades rather than guessing ───────────────────────
# Launching a wrong GUI command on an unrecognised box can hang the tool call
# (the cmd.exe process-tree wait) — path-only is the safe default.
_out="$(_decide "some-new-box" "sample.png")"
if printf '%s' "$_out" | grep -qi 'path-only\|no gui\|headless\|unknown'; then
    pass "an unknown machine degrades to path-only instead of guessing"
else
    fail "unknown machine did not degrade safely: $_out"
fi

echo "=== safety: the three WSL traps are encoded ==="

# These three are why a rewrite that "looks right" hangs or leaks processes. They are
# asserted against the SOURCE because they concern how the launch is spelled, and a
# dry run cannot observe a process that was deliberately not started.

# Trap 1: cmd.exe /c start BLOCKS the calling Bash tool call (WSL waits on the whole
# detached process tree). Start-Process detaches and survives the tool-call boundary.
# Strip comments before asserting — the script documents the trap in prose, and a
# grep over the whole file would flag the warning as if it were the defect.
_code_only() { grep -vE '^[[:space:]]*#' "$HELPER"; }
if _code_only | grep -q 'Start-Process' && ! _code_only | grep -qE 'cmd\.exe[[:space:]]+/c[[:space:]]+start'; then
    pass "uses powershell Start-Process, never 'cmd.exe /c start'"
else
    fail "must use Start-Process and must not use 'cmd.exe /c start' (it blocks the tool call)"
fi

# Trap 2: a \\wsl.localhost UNC path spawns zombie PowerShells (the 2026-03-10 lockout).
if grep -qi 'staging\|wslpath -w\|/mnt/c' "$HELPER"; then
    pass "stages files onto a Windows-native path instead of passing a UNC path"
else
    fail "no Windows-native staging — a UNC path will spawn zombie PowerShells"
fi

# Trap 3: Windows executables must be invoked from a /mnt cwd or the unc-path-guard
# refuses them.
if grep -q 'env -C /mnt\|cd /mnt' "$HELPER"; then
    pass "invokes Windows executables from a /mnt cwd"
else
    fail "Windows exe not invoked from a /mnt cwd — the unc-path-guard will refuse it"
fi

echo "=== argument handling ==="

# ── A missing file is an error, not a launch ───────────────────────────────
if OPEN_FILE_DRY=1 OPEN_FILE_MACHINE=wsl bash "$HELPER" "$_tmp/does-not-exist.png" >/dev/null 2>&1; then
    fail "a nonexistent file should not be dispatched"
else
    pass "a nonexistent file is refused"
fi

# ── No arguments is a usage error ──────────────────────────────────────────
if OPEN_FILE_DRY=1 bash "$HELPER" >/dev/null 2>&1; then
    fail "no arguments should be a usage error"
else
    pass "no arguments is a usage error"
fi

# ── Multiple files all dispatch ────────────────────────────────────────────
# The common real case is a batch of rendered proofs. If only the first opens, the
# session reports success having shown the user one of four images.
_a="$(_mk multi1.png)"; _b="$(_mk multi2.png)"; _c="$(_mk multi3.txt)"
_out="$(OPEN_FILE_DRY=1 OPEN_FILE_MACHINE=wsl bash "$HELPER" "$_a" "$_b" "$_c" 2>/dev/null)"
if [ "$(printf '%s\n' "$_out" | grep -ci 'chrome')" -eq 2 ] \
   && [ "$(printf '%s\n' "$_out" | grep -ci 'notepad')" -eq 1 ]; then
    pass "every file in a batch is dispatched, each by its own type"
else
    fail "batch dispatch wrong: $_out"
fi

# ── A path containing spaces survives ──────────────────────────────────────
_sp="$_tmp/a file with spaces.png"; : > "$_sp"
if OPEN_FILE_DRY=1 OPEN_FILE_MACHINE=wsl bash "$HELPER" "$_sp" 2>/dev/null | grep -qi 'chrome'; then
    pass "a path containing spaces is handled"
else
    fail "a path with spaces was mangled"
fi

# ── Dry run must not launch anything ───────────────────────────────────────
# The guard that lets this suite run on MG's desktop without opening 20 windows.
if OPEN_FILE_DRY=1 OPEN_FILE_MACHINE=wsl bash "$HELPER" "$(_mk dry.png)" 2>&1 \
   | grep -qiE 'would open|dry'; then
    pass "dry run announces the decision instead of launching"
else
    fail "dry run did not identify itself as a dry run"
fi

echo
# ══════════════════════════════════════════════════════════════════════════════
# CFG-681: one Chrome tab per SPACE in the filename
# ══════════════════════════════════════════════════════════════════════════════
# Measured 2026-09-23: two calls on "200 Software Project Assignment — AI First PDP.pdf"
# opened 16 junk tabs on MG's desktop. `-ArgumentList '$win'` hands PowerShell ONE string
# which it passes as the raw command line, so Chrome re-splits it on spaces and treats
# each of the 8 tokens as a URL.
#
# Asserted against the CONSTRUCTED PowerShell command, never by launching anything —
# launching is precisely what put 16 tabs on his screen, and a test must not do that to him.

echo ""
echo "=== open-file.sh: the Windows launch command (CFG-681) ==="

if ! grep -q '^_win_launch_cmd()' "$HELPER"; then
    fail "CFG-681: command construction is not factored into _win_launch_cmd (untestable without launching)"
else
    # shellcheck disable=SC1090
    _cmd=$(bash -c 'source <(sed -n "/^_win_launch_cmd()/,/^}/p" "$0"); _win_launch_cmd chrome.exe "C:\\temp\\cc-open\\200 Software Project Assignment.pdf"' "$HELPER")
    echo "  constructed: $_cmd"

    if printf '%s' "$_cmd" | grep -q -- "-ArgumentList '\"C:\\\\temp\\\\cc-open\\\\200 Software Project Assignment.pdf\"'"; then
        pass "CFG-681: a path with spaces is passed as ONE double-quoted argument"
    else
        fail "CFG-681: a path with spaces is passed as ONE double-quoted argument"
    fi

    # The two fallback branches were already correct — the path is the single-quoted
    # -FilePath positional, which handles spaces. Guard against 'fixing' them too.
    _fb=$(bash -c 'source <(sed -n "/^_win_launch_cmd()/,/^}/p" "$0"); _win_launch_cmd "" "C:\\temp\\a b.pdf"' "$HELPER")
    echo "  fallback:    $_fb"
    if [ "$_fb" = "Start-Process 'C:\\temp\\a b.pdf'" ]; then
        pass "CFG-681: the no-exe fallback stays a single-quoted -FilePath positional"
    else
        fail "CFG-681: the no-exe fallback stays a single-quoted -FilePath positional"
    fi
fi

# Second half of the same incident: the WSL launch path printed NOTHING on success, so the
# calling session could not tell whether it had fired, ran it again, and 8 tabs became 16.
if grep -qE '^[[:space:]]*(echo|printf).*launched' "$HELPER"; then
    pass "CFG-681: the launch path reports what it launched"
else
    fail "CFG-681: the launch path reports what it launched (silent success invites a second run)"
fi

echo "── Summary ──"
echo "  Total:   $((PASSED + FAILED))"
echo "  Passed:  $PASSED"
[ "$FAILED" -gt 0 ] && { echo "  Failed:  $FAILED"; printf '  FAIL: %s\n' "${FAILURES[@]}"; exit 1; }
exit 0
