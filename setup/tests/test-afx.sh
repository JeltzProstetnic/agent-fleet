#!/usr/bin/env bash
# Tests for setup/scripts/afx.sh — the fleet dispatcher (CFG-1093 Q-1093-NAMING/-CMDNAME, CFG-1087 slice):
# `afx <verb> [args…]` runs the fleet script <verb> from the config repo, so rules name a verb instead of a
# platform-specific path. The real Git for Windows checks live in test-windows-gitbash.sh.
source "$(dirname "$0")/test-helpers.sh"

suite_header "afx.sh (fleet dispatcher)"

SCRIPT="$REPO_ROOT/setup/scripts/afx.sh"

# _fixture — a throwaway config repo with verbs of every kind; prints its path
_fixture() {
    local r="$TEST_TMPDIR/repo"
    mkdir -p "$r/setup/scripts" "$r/dms/scripts" "$r/secrets" "$r/global/hooks"
    cp "$REPO_ROOT/global/hooks/lib-detect-repo.sh" "$REPO_ROOT/global/hooks/lib-portable.sh" "$r/global/hooks/"
    cp "$SCRIPT" "$r/setup/scripts/afx.sh"
    printf '#!/usr/bin/env bash\n# repo root sync\necho "SYNC $*"\n' > "$r/sync.sh"
    printf '#!/usr/bin/env bash\n# Say hello with the args\nfor a in "$@"; do echo "ARG[$a]"; done\n' > "$r/setup/scripts/hello.sh"
    printf '#!/usr/bin/env bash\nexit 7\n' > "$r/setup/scripts/rc7.sh"
    printf '#!/usr/bin/env bash\ncat\n' > "$r/setup/scripts/catverb.sh"
    printf '#!/usr/bin/env python3\n"""Python verb."""\nimport sys, json\nprint("PY " + json.dumps(sys.argv))\n' > "$r/setup/scripts/pyecho.py"
    printf '#!/usr/bin/env bash\necho LIB\n' > "$r/setup/scripts/lib-x.sh"
    printf '#!/usr/bin/env bash\necho LIB\n' > "$r/setup/scripts/foo-lib.sh"
    printf '#!/usr/bin/env bash\necho "DMS $*"\n' > "$r/dms/scripts/dmsverb.sh"
    printf '#!/usr/bin/env bash\necho "VAULT $*"\n' > "$r/secrets/vault-manage.sh"
    printf 'print("helper")\n' > "$r/secrets/vault_edit.py"
    printf '#!/usr/bin/env bash\necho INSTALLER\n' > "$r/setup.sh"
    echo "$r"
}

_afx() { local r="$1"; shift; CONFIG_REPO="$r" bash "$SCRIPT" "$@"; }

test_sh_verb_args_verbatim() {
    local r; r=$(_fixture)
    assert_eq $'ARG[a]\nARG[b c]\nARG[]' "$(_afx "$r" hello a "b c" "")" "args reach the script word for word, empty ones included"
}
run_test "afx hello a 'b c' '' → setup/scripts/hello.sh with the args verbatim" test_sh_verb_args_verbatim

test_exit_code_propagates() {
    local r rc; r=$(_fixture); _afx "$r" rc7 >/dev/null 2>&1; rc=$?
    assert_eq "7" "$rc"
}
run_test "the verb's exit code is afx's exit code" test_exit_code_propagates

test_stdin_passes_through() {
    local r; r=$(_fixture)
    assert_eq "piped" "$(echo piped | CONFIG_REPO="$r" bash "$SCRIPT" catverb)"
}
run_test "stdin reaches the verb" test_stdin_passes_through

test_py_verb_runs_with_python() {
    local r out; r=$(_fixture); out=$(_afx "$r" pyecho x "y z")
    assert_contains "$out" "PY [" "the .py verb ran under Python"
    assert_contains "$out" '"x", "y z"]' "args verbatim"
}
run_test "afx pyecho → setup/scripts/pyecho.py under the resolved Python" test_py_verb_runs_with_python

test_py_without_python_is_127() {
    local r out rc; r=$(_fixture)
    out=$(_FLEET_PYTHON=none CONFIG_REPO="$r" bash "$SCRIPT" pyecho 2>&1); rc=$?
    assert_eq "127" "$rc" "no usable Python = command not found"
    assert_contains "$out" "Python"
}
run_test "a .py verb with no usable Python exits 127 and says so" test_py_without_python_is_127

test_native_windows_converts_paths_for_python() {
    local r out stub="$TEST_TMPDIR/stub"; r=$(_fixture); mkdir -p "$stub"
    # cygpath -m stub: /x/y → C:/x/y ; the fake native python prints its argv
    printf '#!/usr/bin/env bash\n[ "$1" = -m ] && shift; echo "C:$1"\n' > "$stub/cygpath"
    printf '#!/usr/bin/env bash\necho "NATIVE $*"\n' > "$stub/fakepy"
    chmod +x "$stub/cygpath" "$stub/fakepy"
    out=$(PATH="$stub:$PATH" PLATFORM=windows _FLEET_PYTHON=fakepy CONFIG_REPO="$r" bash "$SCRIPT" pyecho /c/a.txt --out=/c/o rel/p "-n" "plain")
    assert_eq "NATIVE C:$r/setup/scripts/pyecho.py C:/c/a.txt --out=C:/c/o rel/p -n plain" "$out" \
        "script path, absolute args and --opt=/abs values go native; relative paths and words stay"
}
run_test "native Windows: a .py verb gets native paths (script + absolute args), other args untouched" test_native_windows_converts_paths_for_python

test_sh_args_never_converted() {
    local r out stub="$TEST_TMPDIR/stub"; r=$(_fixture); mkdir -p "$stub"
    printf '#!/usr/bin/env bash\necho "C:$2"\n' > "$stub/cygpath"; chmod +x "$stub/cygpath"
    out=$(PATH="$stub:$PATH" PLATFORM=windows CONFIG_REPO="$r" bash "$SCRIPT" hello /c/a.txt)
    assert_eq "ARG[/c/a.txt]" "$out" "bash understands MSYS paths; only native programs need conversion"
}
run_test "native Windows: a .sh verb's args are passed as-is" test_sh_args_never_converted

test_unknown_verb_exit_2() {
    local r out rc; r=$(_fixture); out=$(_afx "$r" nosuchverb 2>&1); rc=$?
    assert_eq "2" "$rc"
    assert_contains "$out" "unknown verb 'nosuchverb'"
    assert_contains "$out" "afx --list"
}
run_test "an unknown verb exits 2 and points at afx --list" test_unknown_verb_exit_2

test_libs_are_not_verbs() {
    local r rc; r=$(_fixture)
    _afx "$r" lib-x >/dev/null 2>&1; rc=$?; assert_eq "2" "$rc" "lib-*.sh is a library"
    _afx "$r" foo-lib >/dev/null 2>&1; rc=$?; assert_eq "2" "$rc" "*-lib.sh is a library"
}
run_test "library files (lib-*, *-lib) are never verbs" test_libs_are_not_verbs

test_path_like_verbs_refused() {
    local r rc v; r=$(_fixture)
    for v in ../sync setup/scripts/hello hello.sh .hidden -x "" "Hello"; do
        _afx "$r" "$v" >/dev/null 2>&1; rc=$?
        assert_eq "2" "$rc" "verb '$v' must be refused"
    done
}
run_test "path-like, suffixed, dotted, option-like, empty and upper-case verbs are refused (exit 2)" test_path_like_verbs_refused

test_other_dirs_and_alias() {
    local r; r=$(_fixture)
    assert_eq "DMS a" "$(_afx "$r" dmsverb a)" "dms/scripts is searched"
    assert_eq "VAULT status" "$(_afx "$r" vault status)" "vault = secrets/vault-manage.sh"
    assert_eq "VAULT keys" "$(_afx "$r" vault-manage keys)" "and under its own name"
    assert_eq "SYNC deploy" "$(_afx "$r" sync deploy)" "repo-root scripts are verbs"
}
run_test "dms/scripts, secrets/, the repo root and the vault alias resolve" test_other_dirs_and_alias

test_root_and_secrets_are_allowlisted() {
    local r rc; r=$(_fixture)
    _afx "$r" setup >/dev/null 2>&1; rc=$?; assert_eq "2" "$rc" "the root installer is not a verb (one typo from 'afx sync setup')"
    _afx "$r" vault_edit >/dev/null 2>&1; rc=$?; assert_eq "2" "$rc" "vault-manage's helper is not a verb"
    assert_not_contains "$(_afx "$r" --list)" "vault_edit"
}
run_test "only sync (root) and vault/vault-manage (secrets/) resolve outside the script dirs" test_root_and_secrets_are_allowlisted

test_vault_listed_only_when_present() {
    local r; r=$(_fixture); rm -rf "$r/secrets"
    assert_not_contains "$(_afx "$r" --list)" "vault" "a template without secrets/ lists no vault verb"
}
run_test "--list shows vault only where secrets/vault-manage.sh exists" test_vault_listed_only_when_present

test_py_args_untouched_off_windows() {
    local r out; r=$(_fixture)
    out=$(_afx "$r" pyecho $'a\n\n' /abs/p)
    assert_contains "$out" '"a\n\n", "/abs/p"]' "trailing newlines and absolute paths pass unchanged off native Windows"
}
run_test "off native Windows a .py verb's args are passed byte for byte" test_py_args_untouched_off_windows

test_which() {
    local r; r=$(_fixture)
    assert_eq "$r/setup/scripts/hello.sh" "$(_afx "$r" --which hello)"
    local rc; _afx "$r" --which nosuch >/dev/null 2>&1; rc=$?; assert_eq "2" "$rc"
}
run_test "afx --which <verb> prints the script path; unknown → 2" test_which

test_list() {
    local r out rc; r=$(_fixture); out=$(_afx "$r" --list); rc=$?
    assert_eq "0" "$rc"
    assert_contains "$out" "hello"
    assert_contains "$out" "Say hello with the args" "the first comment line is the description"
    assert_contains "$out" "pyecho"
    assert_contains "$out" "dmsverb"
    assert_contains "$out" "vault"
    assert_contains "$out" "sync"
    assert_not_contains "$out" "lib-x"
    assert_not_contains "$out" "foo-lib"
    assert_not_contains "$out" "afx " "the dispatcher is not its own verb"
}
run_test "afx --list prints every verb with its description, libraries excluded" test_list

test_usage() {
    local r out rc; r=$(_fixture)
    out=$(_afx "$r" 2>&1); rc=$?; assert_eq "2" "$rc" "no verb = usage error"; assert_contains "$out" "Usage: afx"
    out=$(_afx "$r" --help 2>&1); rc=$?; assert_eq "0" "$rc"; assert_contains "$out" "Usage: afx"
    out=$(_afx "$r" --bogus 2>&1); rc=$?; assert_eq "2" "$rc" "unknown option"
}
run_test "no args → usage + 2, --help → usage + 0, unknown option → 2" test_usage

test_finds_own_repo_through_symlink() {
    local r out; r=$(_fixture); mkdir -p "$TEST_TMPDIR/bin"
    ln -s "$r/setup/scripts/afx.sh" "$TEST_TMPDIR/bin/afx"
    out=$(cd "$TEST_TMPDIR" && env -u CONFIG_REPO bash "$TEST_TMPDIR/bin/afx" --which hello)
    assert_eq "$r/setup/scripts/hello.sh" "$out" "without CONFIG_REPO the symlink's real location names the repo"
}
run_test "invoked through a symlink with no CONFIG_REPO, afx finds the repo it lives in" test_finds_own_repo_through_symlink

test_no_repo_is_error() {
    local out rc; mkdir -p "$TEST_TMPDIR/empty"
    out=$(CONFIG_REPO="$TEST_TMPDIR/empty" HOME="$TEST_TMPDIR/empty" bash -c 'cp "$1" "$HOME/afx"; bash "$HOME/afx" hello' _ "$SCRIPT" 2>&1); rc=$?
    assert_eq "2" "$rc" "no config repo found"
    assert_contains "$out" "config repo"
}
run_test "no config repo anywhere → exit 2 naming the problem" test_no_repo_is_error

# ── install: ~/.local/bin/afx (+ afx.cmd on native Windows) ──────────────────────────────────────
test_install_links() {
    local r bin="$TEST_TMPDIR/bin2" out; r=$(_fixture)
    out=$(_SYMLINK_MODE=symlink CONFIG_REPO="$r" bash "$r/setup/scripts/afx.sh" --install "$bin" 2>&1)
    assert_eq "$r/setup/scripts/afx.sh" "$(readlink -f "$bin/afx")" "afx is linked to the dispatcher"
    assert_file_not_exists "$bin/afx.cmd" "no .cmd shim off native Windows"
    assert_eq "$r/setup/scripts/hello.sh" "$(CONFIG_REPO="$r" "$bin/afx" --which hello)" "the installed command works"
}
run_test "afx --install <bin> links <bin>/afx to the dispatcher (no .cmd off Windows)" test_install_links

test_install_copy_mode_marker() {
    local r bin="$TEST_TMPDIR/bin3"; r=$(_fixture)
    _SYMLINK_MODE=copy CONFIG_REPO="$r" bash "$r/setup/scripts/afx.sh" --install "$bin" >/dev/null 2>&1
    assert_file_exists "$bin/afx"
    [ -L "$bin/afx" ] && { echo "copy mode made a symlink"; return 1; }
    assert_file_contains "$bin/afx" "afx — fleet dispatcher" "the copy carries the marker that lets a re-install refresh it"
    _SYMLINK_MODE=copy CONFIG_REPO="$r" bash "$r/setup/scripts/afx.sh" --install "$bin" >/dev/null 2>&1
    assert_eq "0" "$?" "re-install over our own copy succeeds"
}
run_test "copy mode installs a marked copy that a re-install may replace" test_install_copy_mode_marker

test_install_never_clobbers_foreign_afx() {
    local r bin="$TEST_TMPDIR/bin4" out rc; r=$(_fixture); mkdir -p "$bin"
    printf '#!/bin/sh\necho someone elses afx\n' > "$bin/afx"
    out=$(_SYMLINK_MODE=symlink CONFIG_REPO="$r" bash "$r/setup/scripts/afx.sh" --install "$bin" 2>&1); rc=$?
    assert_eq "3" "$rc" "a foreign afx is a conflict"
    assert_contains "$out" "not ours"
    assert_file_contains "$bin/afx" "someone elses afx" "the foreign file is untouched"
}
run_test "afx --install refuses (exit 3) to replace an unrelated afx" test_install_never_clobbers_foreign_afx

test_install_windows_writes_cmd_shim() {
    local r bin="$TEST_TMPDIR/bin5" stub="$TEST_TMPDIR/stub" shim; r=$(_fixture); mkdir -p "$stub"
    # cygpath -w stub: /p → C:\p with backslashes
    printf '#!/usr/bin/env bash\n[ "$1" = -w ] || [ "$1" = -m ] && { o=$1; shift; }; p="C:$1"; [ "$o" = -w ] && p="${p//\\//\\\\}"; echo "$p"\n' > "$stub/cygpath"
    chmod +x "$stub/cygpath"
    PATH="$stub:$PATH" PLATFORM=windows _SYMLINK_MODE=copy AFX_WIN_BASH=/fake/git/bin/bash.exe CONFIG_REPO="$r" \
        bash "$r/setup/scripts/afx.sh" --install "$bin" >/dev/null 2>&1
    assert_file_exists "$bin/afx.cmd"
    shim=$(tr -d '\r' < "$bin/afx.cmd")
    assert_contains "$shim" '"C:\fake\git\bin\bash.exe"' "the shim calls the Git Bash that installed it, never the WSL bash alias"
    assert_contains "$shim" "%*" "all arguments pass through"
    assert_contains "$shim" "exit /b" "the verb's exit code comes back"
    assert_contains "$(cat "$bin/afx.cmd")" $'\r' "a .cmd file has CRLF line ends"
}
test_install_never_clobbers_foreign_cmd() {
    local r bin="$TEST_TMPDIR/bin6" stub="$TEST_TMPDIR/stub" rc out; r=$(_fixture); mkdir -p "$stub" "$bin"
    printf '#!/usr/bin/env bash\n[ "$1" = -w ] || [ "$1" = -m ] && shift; echo "C:$1"\n' > "$stub/cygpath"; chmod +x "$stub/cygpath"
    printf '@echo off\r\necho someone else\r\n' > "$bin/afx.cmd"
    out=$(PATH="$stub:$PATH" PLATFORM=windows _SYMLINK_MODE=copy AFX_WIN_BASH=/x/bash.exe CONFIG_REPO="$r" \
        bash "$r/setup/scripts/afx.sh" --install "$bin" 2>&1); rc=$?
    assert_eq "3" "$rc" "a foreign afx.cmd is a conflict"
    assert_file_contains "$bin/afx.cmd" "someone else" "and stays untouched"
}
run_test "native Windows: --install refuses (exit 3) to replace an unrelated afx.cmd" test_install_never_clobbers_foreign_cmd

run_test "native Windows: --install also writes afx.cmd calling the installing Git Bash (PowerShell/cmd)" test_install_windows_writes_cmd_shim

# ── hook messages: routine instructions name verbs; recovery messages keep a path that works without afx ──
H="$REPO_ROOT/global/hooks"

test_hook_verbs_resolve() {
    local verbs v bad=""
    verbs=$(grep -rhoE "afx [a-z0-9][a-z0-9_-]*" "$H" | awk '{print $2}' | sort -u)
    [ -n "$verbs" ] || { echo "    no hook names an afx verb"; return 1; }
    for v in $verbs; do
        CONFIG_REPO="$REPO_ROOT" bash "$SCRIPT" --which "$v" >/dev/null 2>&1 && continue
        # the public template ships no dms/: 04-auto-fix prints its FMS line only when fms-intake.sh exists
        [ "$v" = fms-intake ] && [ ! -f "$REPO_ROOT/dms/scripts/fms-intake.sh" ] && continue
        bad="$bad $v"
    done
    assert_eq "" "$bad" "every verb a hook tells the agent to run exists in the repo"
}
run_test "every 'afx <verb>' named in a hook resolves in this repo" test_hook_verbs_resolve

test_routine_messages_switched() {
    assert_file_contains "$H/checks/04-auto-fix.sh" "afx fms-intake scan"
    assert_file_contains "$H/checks/04-auto-fix.sh" "afx sync check"
    assert_file_contains "$H/checks/04-auto-fix.sh" "afx e2e-podman --source"
    assert_file_contains "$H/checks/08-propagation-drift.sh" "afx sync check"
    assert_file_contains "$H/checks/08-propagation-drift.sh" "afx sync template-push --dry-run"
    assert_file_contains "$H/checks/24-cc-install.sh" "afx cc-install-invariants"
    assert_file_contains "$H/checks/24-cc-install.sh" "afx cc-update"
    if [ -f "$H/checks/28-azure-ai.sh" ]; then   # employer-specific, personal repo only (not propagated)
        assert_file_contains "$H/checks/28-azure-ai.sh" "afx azure-ai"
        assert_file_not_contains "$H/checks/28-azure-ai.sh" "python3 ~/cfg-agent-fleet" "no bare python3 + home path in the AZURE_AI line"
    fi
    assert_file_contains "$H/manifest-push-check.sh" "afx sync template-push --dry-run"
    # …and the old path forms are gone from those messages
    assert_file_not_contains "$H/checks/04-auto-fix.sh" "Run 'bash \$FMS_SCRIPT scan'"
    assert_file_not_contains "$H/checks/04-auto-fix.sh" "Run 'bash \$CONFIG_REPO/sync.sh check'"
    assert_file_not_contains "$H/checks/04-auto-fix.sh" "bash setup/scripts/e2e-podman.sh"
    assert_file_not_contains "$H/checks/08-propagation-drift.sh" "bash \$CONFIG_REPO/sync.sh"
    assert_file_not_contains "$H/checks/24-cc-install.sh" "bash \$_ci_script"
    assert_file_not_contains "$H/manifest-push-check.sh" "bash sync.sh template-push"
}
run_test "routine hook instructions name afx verbs, not script paths" test_routine_messages_switched

test_recovery_messages_keep_paths() {
    # these fire when a deploy may never have run, so afx may not be installed yet
    assert_file_contains "$H/checks/01-sync-state.sh" "Run 'bash \$CONFIG_REPO/sync.sh setup'"
    assert_file_contains "$H/secret-commit-guard.sh" "sync.sh deploy"
}
run_test "recovery messages (sync failed, broken links, secret-guard repair) keep a path that works without afx" test_recovery_messages_keep_paths

test_settings_allow_afx() {
    local n
    n=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["permissions"]["allow"].count("Bash(afx:*)"))' "$REPO_ROOT/setup/config/settings.json")
    assert_eq "1" "$n" "rules say \`afx <verb>\`, so the settings template allows it once (first-word match)"
}
run_test "the settings template allows Bash(afx:*)" test_settings_allow_afx

suite_summary
