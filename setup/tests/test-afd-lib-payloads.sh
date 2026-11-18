#!/usr/bin/env bash
# Tests for AFT-75: afd_push / afd_notify / afd_complete produce valid JSON
# and pass curl timeouts.  Uses a PATH shim for curl — never reaches a real AFD.
source "$(dirname "$0")/test-helpers.sh"

suite_header "AFT-75: afd-lib payload escaping and curl timeouts"

AFD_LIB="$REPO_ROOT/afd/lib/afd-lib.sh"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Create a curl shim that records args to a file and writes the body (-d) to
# a separate file.  The shim always exits 0.
_install_curl_shim() {
  local shim_dir="$TEST_TMPDIR/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/curl" << 'SHIMEOF'
#!/usr/bin/env bash
# Minimal curl shim: record all args, extract -d body
printf '%s\n' "$@" > "$CURL_ARGS_FILE"
i=1
while [ "$i" -le "$#" ]; do
  if [ "${!i}" = "-d" ]; then
    next=$((i+1))
    printf '%s' "${!next}" > "$CURL_BODY_FILE"
    break
  fi
  i=$((i+1))
done
exit 0
SHIMEOF
  chmod +x "$shim_dir/curl"
  export PATH="$shim_dir:$PATH"
  export CURL_ARGS_FILE="$TEST_TMPDIR/curl_args"
  export CURL_BODY_FILE="$TEST_TMPDIR/curl_body"
}

# Source the library fresh with test env
_source_lib() {
  export AFD_URL="http://localhost:9999"
  export AFD_TOKEN="test-token"
  # Unset to get a clean load
  unset _afd_lib_loaded 2>/dev/null || true
  source "$AFD_LIB"
}

# Validate the curl body is parseable JSON and a given key round-trips exactly
_assert_json_roundtrip() {
  local key="$1"
  local expected="$2"
  local label="$3"
  local body
  body=$(cat "$CURL_BODY_FILE")
  # Must parse as JSON
  printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
  assert_eq "0" "$?" "JSON must parse ($label): body=$body"
  # Key value must round-trip
  local actual
  actual=$(printf '%s' "$body" | python3 -c "import json,sys; print(json.load(sys.stdin)['$key'])")
  assert_eq "$expected" "$actual" "round-trip $key ($label): expected=$(printf '%q' "$expected") actual=$(printf '%q' "$actual")"
}

# Assert that the curl args contain a specific flag
_assert_curl_has_flag() {
  local flag="$1"
  local label="$2"
  local args
  args=$(cat "$CURL_ARGS_FILE")
  assert_contains "$args" "$flag" "curl args must contain $flag ($label)"
}

# ── Tests: afd_push ─────────────────────────────────────────────────────────

test_push_escapes_description() {
  _install_curl_shim
  _source_lib
  local desc=$'He said "hello\\world"\nand left'
  afd_push "test-task" "$desc" "pending"
  _assert_json_roundtrip "description" "$desc" "afd_push description"
}
run_test "afd_push: description with quotes, backslash, newline produces valid JSON" test_push_escapes_description

test_push_escapes_task_id() {
  _install_curl_shim
  _source_lib
  local id='task-"tricky\one'
  afd_push "$id" "normal desc" "pending"
  _assert_json_roundtrip "id" "$id" "afd_push id"
}
run_test "afd_push: task_id with quotes and backslash produces valid JSON" test_push_escapes_task_id

test_push_has_curl_timeout() {
  _install_curl_shim
  _source_lib
  afd_push "tid" "desc" "pending"
  _assert_curl_has_flag "--max-time" "afd_push"
  _assert_curl_has_flag "--connect-timeout" "afd_push"
}
run_test "afd_push: curl carries --max-time and --connect-timeout" test_push_has_curl_timeout

# ── Tests: afd_notify ───────────────────────────────────────────────────────

test_notify_escapes_message() {
  _install_curl_shim
  _source_lib
  local msg=$'Alert: "disk\\full"\nplease fix'
  afd_notify "test-host" "$msg" "high" "warning"
  _assert_json_roundtrip "message" "$msg" "afd_notify message"
}
run_test "afd_notify: message with quotes, backslash, newline produces valid JSON" test_notify_escapes_message

test_notify_escapes_machine() {
  _install_curl_shim
  _source_lib
  local machine='host-"special\one'
  afd_notify "$machine" "normal msg" "normal" "info"
  _assert_json_roundtrip "machine" "$machine" "afd_notify machine"
}
run_test "afd_notify: machine with quotes and backslash produces valid JSON" test_notify_escapes_machine

test_notify_has_curl_timeout() {
  _install_curl_shim
  _source_lib
  afd_notify "host" "msg" "normal" "info"
  _assert_curl_has_flag "--max-time" "afd_notify"
  _assert_curl_has_flag "--connect-timeout" "afd_notify"
}
run_test "afd_notify: curl carries --max-time and --connect-timeout" test_notify_has_curl_timeout

# ── Tests: afd_complete ─────────────────────────────────────────────────────

test_complete_has_curl_timeout() {
  _install_curl_shim
  _source_lib
  afd_complete "tid"
  _assert_curl_has_flag "--max-time" "afd_complete"
  _assert_curl_has_flag "--connect-timeout" "afd_complete"
}
run_test "afd_complete: curl carries --max-time and --connect-timeout" test_complete_has_curl_timeout

test_complete_body_is_valid_json() {
  _install_curl_shim
  _source_lib
  afd_complete "tid"
  local body
  body=$(cat "$CURL_BODY_FILE")
  printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
  assert_eq "0" "$?" "afd_complete body must be valid JSON: body=$body"
}
run_test "afd_complete: body is valid JSON" test_complete_body_is_valid_json

# ── Tests: manual escaping fallback (no jq) ─────────────────────────────────

test_push_escapes_without_jq() {
  _install_curl_shim
  # Hide jq from PATH so the manual escaping branch runs
  local orig_path="$PATH"
  mkdir -p "$TEST_TMPDIR/nojq"
  # Symlink everything except jq
  for bin in /usr/bin/*; do
    local name; name=$(basename "$bin")
    [[ "$name" == "jq" ]] && continue
    ln -sf "$bin" "$TEST_TMPDIR/nojq/$name" 2>/dev/null || true
  done
  export PATH="$TEST_TMPDIR/bin:$TEST_TMPDIR/nojq"
  _source_lib
  local desc=$'He said "hello\\world"\nand left'
  afd_push "test-task" "$desc" "pending"
  export PATH="$orig_path"
  _assert_json_roundtrip "description" "$desc" "afd_push no-jq fallback"
}
run_test "afd_push: manual escaping fallback without jq produces valid JSON" test_push_escapes_without_jq

test_notify_escapes_without_jq() {
  _install_curl_shim
  local orig_path="$PATH"
  mkdir -p "$TEST_TMPDIR/nojq"
  for bin in /usr/bin/*; do
    local name; name=$(basename "$bin")
    [[ "$name" == "jq" ]] && continue
    ln -sf "$bin" "$TEST_TMPDIR/nojq/$name" 2>/dev/null || true
  done
  export PATH="$TEST_TMPDIR/bin:$TEST_TMPDIR/nojq"
  _source_lib
  local msg=$'Alert: "disk\\full"\nplease fix'
  afd_notify "test-host" "$msg" "high" "warning"
  export PATH="$orig_path"
  _assert_json_roundtrip "message" "$msg" "afd_notify no-jq fallback"
}
run_test "afd_notify: manual escaping fallback without jq produces valid JSON" test_notify_escapes_without_jq

# ── Tests: empty-URL guard (silent no-op) ───────────────────────────────────

test_push_noop_without_url() {
  _install_curl_shim
  _source_lib
  export AFD_URL=""
  rm -f "$CURL_ARGS_FILE" "$CURL_BODY_FILE"
  afd_push "tid" "desc" "pending" || true
  assert_file_not_exists "$CURL_ARGS_FILE" "curl must not be called when AFD_URL is empty"
}
run_test "afd_push: silent no-op when AFD_URL is empty" test_push_noop_without_url

test_notify_noop_without_url() {
  _install_curl_shim
  _source_lib
  export AFD_URL=""
  rm -f "$CURL_ARGS_FILE" "$CURL_BODY_FILE"
  afd_notify "host" "msg" || true
  assert_file_not_exists "$CURL_ARGS_FILE" "curl must not be called when AFD_URL is empty"
}
run_test "afd_notify: silent no-op when AFD_URL is empty" test_notify_noop_without_url

suite_summary
