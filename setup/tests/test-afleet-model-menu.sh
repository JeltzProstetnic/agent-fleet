#!/usr/bin/env bash
# test-afleet-model-menu.sh — model-selection submenu (CFG-510) and its wiring into
# the launcher. Split out of test-afleet-local-model.sh under CFG-523 so the file
# name pairs with setup/scripts/afleet-model-menu.sh, as the convention requires.
#
# Pure unit tests: never starts LM Studio, never loads a model, never launches
# Claude Code. The on-disk column is stubbed so results do not depend on which
# GGUFs happen to be downloaded on the machine running the suite.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AFLEET="$REPO_ROOT/setup/scripts/afleet.sh"
MENU="$REPO_ROOT/setup/scripts/afleet-model-menu.sh"
LIB="$REPO_ROOT/setup/scripts/afleet-lib.sh"
CONF="$REPO_ROOT/setup/config/local-models.conf"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
chk() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '\n== afleet model menu ==\n'

# --- static ------------------------------------------------------------------
bash -n "$MENU" 2>/dev/null && ok "model menu syntax valid" || bad "model menu syntax valid"
bash -n "$LIB"  2>/dev/null && ok "afleet-lib.sh syntax valid" || bad "afleet-lib.sh syntax valid"
for fn in build_model_rows render_model_menu resolve_model_selection; do
  grep -q "^${fn}()" "$MENU" && ok "menu defines $fn" || bad "menu defines $fn"
done

NO_COLOR=1
# shellcheck disable=SC1090
source "$LIB"
# Deterministic stub: "here" is on disk, everything else is not.
alm_model_size_mib() { case "${ALM_KEY:-}" in *here*) echo 4000 ;; *) echo 0 ;; esac; }
# shellcheck disable=SC1090
source "$MENU"

mkdir -p "$TMP/mm"
cat > "$TMP/mm/models.conf" <<'EOF'
# this comment must never become a row
here  | pub/here-model@q4_k_m | 32768  | max | 3600 | lean
gone  | pub/gone-model        | 262144 | max | 1800 | readonly
EOF
ROWS=$(build_model_rows "$TMP/mm/models.conf")

chk "row 0 is cloud Opus with an empty alias" \
  "$(echo "$ROWS" | awk -F'|' 'NR==1 {print $1"|"$2"|"$3"|"$4"|"$5"|"$6}')" "0||Opus (cloud)|—|cloud|cloud"
chk "an on-disk model is marked ready" \
  "$(echo "$ROWS" | awk -F'|' 'NR==2 {print $1"|"$2"|"$3"|"$4"|"$5"|"$6}')" "1|here|here-model|32k|lean|ready"
chk "a model that is not downloaded is marked missing" \
  "$(echo "$ROWS" | awk -F'|' 'NR==3 {print $1"|"$2"|"$3"|"$4"|"$5"|"$6}')" "2|gone|gone-model|256k|readonly|missing"
chk "a comment line never becomes a row" "$(echo "$ROWS" | wc -l)" "3"

# Context is PINNED and shown in the menu — a wrong number here misleads the choice.
chk "context 32768 renders as 32k"   "$(_format_ctx 32768)"  "32k"
chk "context 262144 renders as 256k" "$(_format_ctx 262144)" "256k"
chk "a non-round context is left alone" "$(_format_ctx 1000)" "1000"

# Every alias in the REAL conf must appear — a model you cannot see you cannot pick.
REAL_AL=$(grep -vE '^\s*(#|$)' "$CONF" | awk -F'|' '{gsub(/ /,"",$1); print $1}' | sort | paste -sd' ' -)
MENU_AL=$(build_model_rows "$CONF" | awk -F'|' 'NR>1 {print $2}' | sort | paste -sd' ' -)
chk "menu lists every alias in local-models.conf" "$MENU_AL" "$REAL_AL"

# --- per-model "why you'd pick this" (7th field) ----------------------------
# A row must carry enough to CHOOSE without opening the conf or the docs.
for a in coder qwen14 qwen36 gemma4 ask; do
  [[ -n "$(_model_why "$a")" ]] && ok "alias '$a' has a description" || bad "alias '$a' has a description"
done
chk "an alias with no entry falls back to empty, not an error" "$(_model_why zzz-unknown)" ""
chk "cloud row carries its own description" \
  "$(echo "$ROWS" | awk -F'|' 'NR==1 {print $7}')" "the normal session — full fleet profile, all tools"
# Descriptions must never become a SECOND model list — the conf stays authoritative.
cat > "$TMP/mm/new.conf" <<'EOF'
brandnew | pub/brand-new-model | 65536 | max | 3600 | lean
EOF
NEWROW=$(build_model_rows "$TMP/mm/new.conf" | awk -F'|' 'NR==2')
chk "a conf row with no description still appears in full" \
  "$(echo "$NEWROW" | awk -F'|' '{print $1"|"$2"|"$3"|"$4"|"$5}')" "1|brandnew|brand-new-model|64k|lean"
chk "and its description is simply empty" "$(echo "$NEWROW" | awk -F'|' '{print $7}')" ""
# Render to a file first: `grep -q` exits early, and under `set -o pipefail` the
# resulting SIGPIPE would fail the pipeline regardless of what was matched.
build_model_rows "$TMP/mm/new.conf" | render_model_menu > "$TMP/mm/new.txt" 2>/dev/null
grep -q "brandnew" "$TMP/mm/new.txt" && ok "a newly added conf row renders without a description" \
  || bad "a newly added conf row renders without a description" "$(cat "$TMP/mm/new.txt")"

# --- selection resolution ---------------------------------------------------
chk "option 0 selects cloud (empty MODEL_ARG)" "$(echo "$ROWS" | resolve_model_selection 0)" ""
chk "a numbered row selects its alias"         "$(echo "$ROWS" | resolve_model_selection 1)" "here"
chk "typing the alias also selects it"         "$(echo "$ROWS" | resolve_model_selection gone)" "gone"
echo "$ROWS" | resolve_model_selection 99 >/dev/null 2>&1 \
  && bad "an unknown selection must not resolve" || ok "an unknown selection must not resolve"

# --- rendering --------------------------------------------------------------
MR="$TMP/mm/render.txt"
build_model_rows "$TMP/mm/models.conf" | render_model_menu > "$MR" 2>/dev/null
grep -q "here-model.*on disk" "$MR" && ok "an on-disk model renders as present" \
  || bad "an on-disk model renders as present" "$(cat "$MR")"
grep -q "gone-model.*not downloaded" "$MR" && ok "a missing model renders as not downloaded" \
  || bad "a missing model renders as not downloaded" "$(cat "$MR")"
# The read-only profile denies Write/Edit/Bash in settings. It must not look like
# just another option — the marker and the legend carry that even without colour.
grep -q "gone-model.*⚠ readonly" "$MR" && ok "readonly profile is marked distinctly" \
  || bad "readonly profile is marked distinctly"
grep -q "here-model.*⚠" "$MR" && bad "a non-readonly row must carry no warning marker" \
  || ok "a non-readonly row must carry no warning marker"
grep -q "DENIED in settings" "$MR" && ok "menu explains what readonly costs" \
  || bad "menu explains what readonly costs"
grep -q 'prof_color="\$C_BRED"' "$MENU" && ok "readonly also gets its own colour" \
  || bad "readonly also gets its own colour"
grep -q "Opus (cloud)" "$MR" && ok "cloud Opus is offered as the default row" \
  || bad "cloud Opus is offered as the default row"
# The alias is what you type at the CLI (`af <proj> <alias>`) — it must be visible.
grep -qE "^│      here +│$" "$MR" && ok "the CLI alias is shown under its row" \
  || bad "the CLI alias is shown under its row" "$(cat "$MR")"

# --- afleet wiring ----------------------------------------------------------
DASHL=$(grep -n '^\s*-\*)' "$AFLEET" | head -1 | cut -d: -f1)
grep -q '^\s*--models|-m)' "$AFLEET" && ok "--models/-m flag is parsed" || bad "--models/-m flag is parsed"
MODL=$(grep -n '^\s*--models|-m)' "$AFLEET" | head -1 | cut -d: -f1)
if [ -n "$MODL" ] && [ -n "$DASHL" ] && [ "$MODL" -lt "$DASHL" ]; then
  ok "--models is matched before the -* catch-all"
else bad "--models is matched before the -* catch-all" "models=$MODL dash=$DASHL"; fi
grep -q 'run_model_picker' "$AFLEET" && ok "afleet wires up the model picker" \
  || bad "afleet wires up the model picker"

# --- `af -m` runs the model menu FIRST (MG 2026-08-13) ----------------------
# From a non-project cwd the project picker used to run first, which made `af -m`
# indistinguishable from a plain `af` — the reported "does nothing" symptom.
MPICK=$(grep -n 'SHOW_MODEL_PICKER:-false' "$AFLEET" | head -1 | cut -d: -f1)
PPICK=$(grep -n 'if \$SHOW_PICKER; then' "$AFLEET" | head -1 | cut -d: -f1)
if [ -n "$MPICK" ] && [ -n "$PPICK" ] && [ "$MPICK" -lt "$PPICK" ]; then
  ok "-m opens the model menu BEFORE the project picker"
else bad "-m opens the model menu BEFORE the project picker" "model=$MPICK project=$PPICK"; fi
# It must also precede project RESOLUTION, or a bad project arg pre-empts the menu.
PRES=$(grep -n '^    # ── Project resolution' "$AFLEET" | head -1 | cut -d: -f1)
if [ -n "$MPICK" ] && [ -n "$PRES" ] && [ "$MPICK" -lt "$PRES" ]; then
  ok "-m opens the model menu before project resolution"
else bad "-m opens the model menu before project resolution" "model=$MPICK resolve=$PRES"; fi

# --- picker shortcut is '@', not a letter (MG 2026-08-13) -------------------
# Child rows are labelled a..z, so ANY letter can collide with a real project. On
# this fleet 'm' was pdp, so the advertised shortcut opened a project instead. '@'
# cannot be a label, so no collision guard is needed and none must be relied on.
grep -q '\[@\]%b model' "$LIB" && ok "project picker advertises [@] for the model submenu" \
  || bad "project picker advertises [@] for the model submenu"
grep -q '\[m\]%b model' "$LIB" && bad "the old [m] hint must be gone — it could never fire" \
  || ok "the old [m] hint is gone"
grep -q '"\$sel" == "@"' "$AFLEET" && ok "picker accepts @ as the model shortcut" \
  || bad "picker accepts @ as the model shortcut"
grep -q 'grep -qx "m"' "$AFLEET" && bad "the 'm' collision guard must be gone with the 'm' key" \
  || ok "no collision guard left behind"
# Regression: '@' must never be a project label, or the shortcut breaks the same way.
LABELS=$(printf '%s\n' "$(parse_dashboard_cache 2>/dev/null | PICKER_SHOW_ALL=1 build_display_list 2>/dev/null | cut -d'|' -f1)")
if printf '%s\n' "$LABELS" | grep -qx '@'; then
  bad "no project row may be labelled @"
else ok "no project row is labelled @"; fi

# --- lockout safety ---------------------------------------------------------
# The menu must be sourced lazily, behind a syntax guard, and never on the boot
# path — a fault in it costs a submenu, not the whole launcher.
grep -q 'bash -n "$menu"' "$AFLEET" && ok "menu is sourced behind a bash -n guard" \
  || bad "menu is sourced behind a bash -n guard"
chk "afleet resolves the menu module in exactly one place (lazy source only)" \
  "$(grep -c '_AFLEET_DIR/afleet-model-menu\.sh' "$AFLEET")" "1"
# That one place must be inside run_model_picker, not the boot path.
if [ "$(grep -n '_AFLEET_DIR/afleet-model-menu\.sh' "$AFLEET" | cut -d: -f1)" \
     -gt "$(grep -n '^run_model_picker()' "$AFLEET" | cut -d: -f1)" ]; then
  ok "menu module is only resolved inside run_model_picker"
else bad "menu module is only resolved inside run_model_picker"; fi
chk "both pickers quit on q" \
  "$(grep -c 'sel" == "q" || "\$sel" == "Q" \]\] && exit 0' "$AFLEET")" "2"

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
