#!/usr/bin/env bash
# test-settings-default-mode.sh — CFG-756: the fleet pins permissions.defaultMode.
# CC 2.1.284+ starts a session in AUTO mode when no mode is configured; the fleet
# pins "auto" explicitly (2026-10-18) so behaviour is identical across updates.
# Tests the merged artifact json-merge.py writes, not only the template.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MERGE="$REPO/setup/scripts/json-merge.py"
BASE="$REPO/setup/config/settings.json"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
mode() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('permissions',{}).get('defaultMode'))" "$1"; }

echo "test-settings-default-mode.sh"

got=$(mode "$BASE")
[[ "$got" == "auto" ]] && ok "template pins defaultMode (got: $got)" || bad "template pins defaultMode auto (got: $got)"

echo '{"permissions":{"allow":["Bash(ls:*)"]},"env":{"SECRET":"x"}}' > "$TMP/live-nomode.json"
python3 "$MERGE" "$BASE" "$TMP/live-nomode.json" /nonexistent > "$TMP/out1.json"
got=$(mode "$TMP/out1.json")
[[ "$got" == "auto" ]] && ok "merge into live without a mode sets it (got: $got)" || bad "merge into live without a mode sets auto (got: $got)"

echo '{"permissions":{"allow":["Bash(ls:*)"],"defaultMode":"default"}}' > "$TMP/live-other.json"
python3 "$MERGE" "$BASE" "$TMP/live-other.json" /nonexistent > "$TMP/out2.json"
got=$(mode "$TMP/out2.json")
[[ "$got" == "auto" ]] && ok "base mode wins over a drifted live mode (got: $got)" || bad "base mode wins over a drifted live mode (got: $got)"

has=$(python3 -c "import json;a=json.load(open('$TMP/out1.json'))['permissions']['allow'];print('Bash(ls:*)' in a)")
[[ "$has" == "True" ]] && ok "live-only allow entries survive (got: $has)" || bad "live-only allow entries survive (got: $has)"

sec=$(python3 -c "import json;print(json.load(open('$TMP/out1.json'))['env'].get('SECRET'))")
[[ "$sec" == "x" ]] && ok "live env secrets survive (got: $sec)" || bad "live env secrets survive (got: $sec)"

echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
[[ $FAIL -eq 0 ]]
