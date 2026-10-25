#!/usr/bin/env bash
# TDD tests for setup/scripts/kind-tools-check.sh — CFG-829: onboarding suggests the tools
# the user's project kinds need, with an install hint for this OS. Suggest only: the script
# never installs anything. Fixture conf + a controlled PATH; no real package manager runs.
source "$(dirname "$0")/test-helpers.sh"

SCRIPT="$REPO_ROOT/setup/scripts/kind-tools-check.sh"
REAL_CONF="$REPO_ROOT/setup/config/project-kind-tools.conf"

suite_header "kind-tools-check.sh (CFG-829: per-kind tool suggestions)"

make_fixture() {
    BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
    printf '#!/bin/sh\nexit 0\n' > "$BIN/zzhave"; chmod +x "$BIN/zzhave"
    CONF="$TEST_TMPDIR/kinds.conf"
    cat > "$CONF" << 'EOF'
# kind | tool | check | apt | dnf | pacman | brew | why
all     | zzhave    | command -v zzhave    | zzhave    | zzhave    | zzhave    | zzhave    | always needed
all     | zzmissall | command -v zzmissall | zzmissall | zzmissall | zzmissall | zzmissall | the picker
writing | zzpandoc  | command -v zzpandoc  | pandoc    | pandoc    | pandoc    | pandoc    | markdown to docx/pdf
code    | zzpodman  | command -v zzpodman  | podman    | podman    | podman    | podman    | containers
code    | zzhave    | command -v zzhave    | zzhave    | zzhave    | zzhave    | zzhave    | duplicate across kinds
EOF
    export KIND_TOOLS_CONF="$CONF" PATH="$BIN:/usr/bin:/bin"
}
OUT=""; RC=0
run() { RC=0; OUT=$(bash "$SCRIPT" "$@" 2>&1) || RC=$?; }

test_all_kind_always_checked() {
    make_fixture; KIND_TOOLS_OS=apt run
    assert_contains "$OUT" "zzmissall" "the 'all' row must be checked with no kind given" || return 1
    assert_not_contains "$OUT" "zzpandoc" "kind rows must not appear when the kind was not named"
}
run_test "'all' rows are always checked; unnamed kinds are not" test_all_kind_always_checked

test_named_kind_and_os_hint() {
    make_fixture; KIND_TOOLS_OS=dnf run writing
    assert_contains "$OUT" "zzpandoc" "a missing tool of a named kind must be listed" || return 1
    assert_contains "$OUT" "sudo dnf install pandoc" "the install hint must match the OS (dnf)" || return 1
    assert_contains "$OUT" "markdown to docx/pdf" "the reason must be shown"
}
run_test "a named kind's missing tool is listed with the OS install hint" test_named_kind_and_os_hint

test_present_tools_not_listed_and_dedup() {
    make_fixture; KIND_TOOLS_OS=apt run code writing
    assert_not_contains "$OUT" "zzhave" "a present tool must not be suggested" || return 1
    assert_eq "1" "$(grep -c 'zzmissall' <<<"$OUT")" "a tool must be listed once even if several kinds name it"
}
run_test "present tools are not suggested; duplicates collapse" test_present_tools_not_listed_and_dedup

test_exit_codes() {
    make_fixture; KIND_TOOLS_OS=apt run code
    assert_eq "1" "$RC" "exit 1 when something is missing (got $RC)" || return 1
    printf '#!/bin/sh\nexit 0\n' > "$BIN/zzmissall"; printf '#!/bin/sh\nexit 0\n' > "$BIN/zzpodman"
    chmod +x "$BIN/zzmissall" "$BIN/zzpodman"
    KIND_TOOLS_OS=apt run code
    assert_eq "0" "$RC" "exit 0 when nothing is missing (got $RC: $OUT)"
}
run_test "exit 1 when tools are missing, 0 when all present" test_exit_codes

test_unknown_kind() {
    make_fixture; KIND_TOOLS_OS=apt run nosuchkind
    assert_eq "2" "$RC" "an unknown kind must exit 2 (got $RC)" || return 1
    assert_contains "$OUT" "writing" "the error must list the known kinds"
}
run_test "an unknown kind exits 2 and lists the known kinds" test_unknown_kind

test_never_installs() {
    make_fixture
    grep -qE '(apt|apt-get|dnf|pacman|brew)[[:space:]]+(install|-S)' <(grep -vE '^[[:space:]]*#|echo|printf|hint' "$SCRIPT") \
        && { echo "    the script appears to run a package manager" >&2; return 1; } || true
}
run_test "the script never runs a package manager itself" test_never_installs

# The product: the real conf parses, has 8 fields per row, and lists fzf under 'all'.
test_real_conf() {
    local bad
    bad=$(awk -F'|' '!/^[[:space:]]*(#|$)/ && NF!=8 {print NR": "NF}' "$REAL_CONF")
    [[ -z "$bad" ]] || { echo "    rows without 8 fields: $bad" >&2; return 1; }
    awk -F'|' '!/^[[:space:]]*#/ {gsub(/ /,"",$1); gsub(/ /,"",$2); if ($1=="all" && $2=="fzf") f=1} END {exit !f}' "$REAL_CONF" \
        || { echo "    fzf is not an 'all' row" >&2; return 1; }
}
run_test "real conf: 8 fields per row; fzf is an 'all' tool" test_real_conf

suite_summary
