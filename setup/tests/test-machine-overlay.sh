#!/usr/bin/env bash
# Tests for CFG-296: Machine variance directory overlay system
# Tests detect_machine_dir(), resolve_config_file(), json-overlay.py,
# and deploy_settings integration with machine overlays.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

COMMON_SH="$REPO_ROOT/sync-lib/common.sh"
DEPLOY_SH="$REPO_ROOT/sync-lib/deploy.sh"
PRE_DEPLOY_SH="$REPO_ROOT/sync-lib/pre-deploy.sh"
JSON_OVERLAY="$REPO_ROOT/setup/scripts/json-overlay.py"

suite_header "Machine Overlay Tests (CFG-296)"

# Helper: source common.sh with stubbed dependencies
# Fixture machine map (CFG-700): generic hosts/users, never the owner's.
write_fixture_map() {
    local repo_dir="$1"
    mkdir -p "$repo_dir/setup/config/machines"
    [[ -f "$repo_dir/setup/config/machines/machine-map.conf" ]] && return 0
    cat > "$repo_dir/setup/config/machines/machine-map.conf" <<'MAP'
# fixture map — <host-glob>[:<user>] <overlay>, first match wins

winbox-*            wsl
handheld*           steamos
console*            steamos
cloudhost           vps
ws*:alice           fedora-home
ws*:bob             office
homeserver*:alice   nuc
corpbook*:carol     ivbook
MAP
}

source_common() {
    local repo_dir="$1"
    write_fixture_map "$repo_dir"
    SCRIPT_DIR="$repo_dir"
    GLOBAL_DIR="$repo_dir/global"
    # Stub lib-portable.sh sourcing (not needed for these functions)
    source "$COMMON_SH"
}

# ══════════════════════════════════════════════════════════════════════════════
# detect_machine_dir tests
# ══════════════════════════════════════════════════════════════════════════════

test_detect_wsl() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="winbox-32:alice"
        local result
        result=$(detect_machine_dir)
        assert_eq "wsl" "$result" "winbox-* hostname should map to wsl"
    )
}

test_detect_steamos_handheld() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="handheld:dave"
        local result
        result=$(detect_machine_dir)
        assert_eq "steamos" "$result" "handheld* hostname should map to steamos"
    )
}

test_detect_steamos_console() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="console7:dave"
        local result
        result=$(detect_machine_dir)
        assert_eq "steamos" "$result" "console* hostname should map to steamos"
    )
}

test_detect_fedora_home() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="ws42:alice"
        local result
        result=$(detect_machine_dir)
        assert_eq "fedora-home" "$result" "ws* + alice should map to fedora-home"
    )
}

test_detect_office() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="ws42:bob"
        local result
        result=$(detect_machine_dir)
        assert_eq "office" "$result" "ws* + bob should map to office"
    )
}

test_detect_vps() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="cloudhost:root"
        local result
        result=$(detect_machine_dir)
        assert_eq "vps" "$result" "cloudhost should map to vps"
    )
}

test_detect_nuc() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="homeserver01:alice"
        local result
        result=$(detect_machine_dir)
        assert_eq "nuc" "$result" "homeserver* + alice should map to nuc"
    )
}

test_detect_ivbook() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="corpbook7051:carol"
        local result
        result=$(detect_machine_dir)
        assert_eq "ivbook" "$result" "corpbook* + carol should map to ivbook"
    )
}

test_detect_ivbook_wrong_user() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="corpbook7051:mallory"
        local result
        result=$(detect_machine_dir)
        assert_eq "" "$result" "corpbook* with another user should not map to ivbook"
    )
}

test_detect_unknown() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="randombox:someuser"
        local result
        result=$(detect_machine_dir)
        assert_eq "" "$result" "Unknown hostname should return empty string"
    )
}

test_detect_machine_override_env() {
    (
        source_common "$TEST_TMPDIR"
        MACHINE_OVERRIDE="winbox-abc:alice"
        local result
        result=$(detect_machine_dir)
        assert_eq "wsl" "$result" "MACHINE_OVERRIDE should be used for hostname:user"
    )
}

# ── machine-map.conf precedence (CFG-700 step 1) ──

test_map_first_match_wins() {
    (
        local repo="$TEST_TMPDIR/firstmatch"
        mkdir -p "$repo/setup/config/machines"
        printf 'box*  alpha\nbox1  beta\n' > "$repo/setup/config/machines/machine-map.conf"
        source_common "$repo"
        MACHINE_OVERRIDE="box1:anyone"
        assert_eq "alpha" "$(detect_machine_dir)" "first matching line wins"
    )
}

test_map_ignores_comments_and_blank_lines() {
    (
        local repo="$TEST_TMPDIR/comments"
        mkdir -p "$repo/setup/config/machines"
        printf '# box*  wrong\n\n   \nbox*  right  # trailing comment\n' > "$repo/setup/config/machines/machine-map.conf"
        source_common "$repo"
        MACHINE_OVERRIDE="box9:u"
        assert_eq "right" "$(detect_machine_dir)" "comments and blank lines are skipped"
    )
}

test_fleet_machine_env_beats_map() {
    (
        source_common "$TEST_TMPDIR"
        unset MACHINE_OVERRIDE
        FLEET_MACHINE="office"
        assert_eq "office" "$(detect_machine_dir)" "FLEET_MACHINE names the overlay directly"
    )
}

test_machine_override_beats_fleet_machine() {
    (
        source_common "$TEST_TMPDIR"
        FLEET_MACHINE="office"
        MACHINE_OVERRIDE="cloudhost:root"
        assert_eq "vps" "$(detect_machine_dir)" "MACHINE_OVERRIDE (test input) wins over FLEET_MACHINE"
    )
}

test_local_machine_map_fallback() {
    (
        local repo="$TEST_TMPDIR/nomap"
        mkdir -p "$repo/setup/config/machines"
        printf 'other*  wsl\n' > "$repo/setup/config/machines/machine-map.conf"
        source_common "$repo"
        local_machine_map() { [[ "$1" == "lonely" && "$2" == "u" ]] && echo "nuc"; }
        MACHINE_OVERRIDE="lonely:u"
        assert_eq "nuc" "$(detect_machine_dir)" "local_machine_map (sync.local.sh) used when the map has no match"
    )
}

test_no_map_no_hook_is_empty() {
    (
        local repo="$TEST_TMPDIR/bare"
        mkdir -p "$repo/setup/config/machines"
        printf '# empty\n' > "$repo/setup/config/machines/machine-map.conf"
        source_common "$repo"
        rm -f "$repo/setup/config/machines/machine-map.conf"
        MACHINE_OVERRIDE="winbox-1:alice"
        assert_eq "" "$(detect_machine_dir)" "missing map and no hook → empty"
    )
}

test_map_example_ships_and_parses() {
    (
        local ex="$REPO_ROOT/setup/config/machines/machine-map.conf.example"
        assert_file_exists "$ex" "machine-map.conf.example ships with the repo"
        local repo="$TEST_TMPDIR/example"
        mkdir -p "$repo/setup/config/machines"
        cp "$ex" "$repo/setup/config/machines/machine-map.conf"
        source_common "$repo"
        MACHINE_OVERRIDE="my-desktop-01:me"
        assert_eq "wsl" "$(detect_machine_dir)" "example map resolves its own documented sample host"
    )
}

# Personal-only: the real map must resolve today's fleet. Skips where the conf is absent (template).
test_real_map_resolves_fleet() {
    local conf="$REPO_ROOT/setup/config/machines/machine-map.conf"
    if [[ ! -f "$conf" ]]; then
        echo "  SKIP: no real machine-map.conf (template checkout)"; return 0
    fi
    (
        source_common "$REPO_ROOT"
        local pair want got
        while read -r pair want; do
            MACHINE_OVERRIDE="$pair"
            got=$(detect_machine_dir)
            assert_eq "$want" "$got" "real map: $pair"
        done < "$REPO_ROOT/setup/config/machines/machine-map.expect"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# resolve_config_file tests
# ══════════════════════════════════════════════════════════════════════════════

test_resolve_returns_overlay_when_exists() {
    (
        local repo="$TEST_TMPDIR/repo"
        mkdir -p "$repo/setup/config/machines/wsl"
        echo '{}' > "$repo/setup/config/settings.json"
        echo '{"env":{}}' > "$repo/setup/config/machines/wsl/settings.json"

        source_common "$repo"
        MACHINE_OVERRIDE="winbox-xyz:alice"
        local result
        result=$(resolve_config_file "settings.json")
        assert_eq "$repo/setup/config/machines/wsl/settings.json" "$result" \
            "Should return overlay path when machine overlay exists"
    )
}

test_resolve_returns_base_when_no_overlay() {
    (
        local repo="$TEST_TMPDIR/repo"
        mkdir -p "$repo/setup/config/machines/wsl"
        echo '{}' > "$repo/setup/config/settings.json"
        # No overlay file for wsl

        source_common "$repo"
        MACHINE_OVERRIDE="winbox-xyz:alice"
        local result
        result=$(resolve_config_file "settings.json")
        assert_eq "$repo/setup/config/settings.json" "$result" \
            "Should return base path when no overlay file exists"
    )
}

test_resolve_returns_base_for_unknown_machine() {
    (
        local repo="$TEST_TMPDIR/repo"
        mkdir -p "$repo/setup/config"
        echo '{}' > "$repo/setup/config/settings.json"

        source_common "$repo"
        MACHINE_OVERRIDE="randombox:user"
        local result
        result=$(resolve_config_file "settings.json")
        assert_eq "$repo/setup/config/settings.json" "$result" \
            "Should return base path for unknown machine"
    )
}

test_resolve_returns_empty_when_neither_exists() {
    (
        local repo="$TEST_TMPDIR/repo"
        mkdir -p "$repo/setup/config"
        # No base file, no overlay

        source_common "$repo"
        MACHINE_OVERRIDE="winbox-xyz:alice"
        local result
        result=$(resolve_config_file "nonexistent.json")
        assert_eq "" "$result" \
            "Should return empty when neither base nor overlay exists"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# json-overlay.py tests
# ══════════════════════════════════════════════════════════════════════════════

test_overlay_empty_overlay_returns_base() {
    (
        echo '{"key":"value","nested":{"a":1}}' > "$TEST_TMPDIR/base.json"
        echo '{}' > "$TEST_TMPDIR/overlay.json"

        local result
        result=$(python3 "$JSON_OVERLAY" "$TEST_TMPDIR/base.json" "$TEST_TMPDIR/overlay.json")
        # base should be unchanged
        assert_contains "$result" '"key": "value"' "Base key should be preserved"
        assert_contains "$result" '"a": 1' "Base nested key should be preserved"
    )
}

test_overlay_scalar_override() {
    (
        echo '{"key":"old","other":"keep"}' > "$TEST_TMPDIR/base.json"
        echo '{"key":"new"}' > "$TEST_TMPDIR/overlay.json"

        local result
        result=$(python3 "$JSON_OVERLAY" "$TEST_TMPDIR/base.json" "$TEST_TMPDIR/overlay.json")
        assert_contains "$result" '"key": "new"' "Overlay scalar should win"
        assert_contains "$result" '"other": "keep"' "Base-only key should be preserved"
    )
}

test_overlay_nested_dict_merge() {
    (
        echo '{"env":{"A":"1","B":"2"}}' > "$TEST_TMPDIR/base.json"
        echo '{"env":{"B":"override","C":"3"}}' > "$TEST_TMPDIR/overlay.json"

        local result
        result=$(python3 "$JSON_OVERLAY" "$TEST_TMPDIR/base.json" "$TEST_TMPDIR/overlay.json")
        assert_contains "$result" '"A": "1"' "Base-only nested key preserved"
        assert_contains "$result" '"B": "override"' "Overlay nested key wins"
        assert_contains "$result" '"C": "3"' "New overlay nested key added"
    )
}

test_overlay_list_union() {
    (
        cat > "$TEST_TMPDIR/base.json" <<'EOF'
{"permissions":{"allow":["Bash(git:*)","Bash(ls:*)"]}}
EOF
        cat > "$TEST_TMPDIR/overlay.json" <<'EOF'
{"permissions":{"allow":["Bash(ls:*)","Bash(powershell.exe:*)"]}}
EOF

        local result
        result=$(python3 "$JSON_OVERLAY" "$TEST_TMPDIR/base.json" "$TEST_TMPDIR/overlay.json")
        assert_contains "$result" '"Bash(git:*)"' "Base-only list item preserved"
        assert_contains "$result" '"Bash(powershell.exe:*)"' "Overlay-only list item added"
        assert_contains "$result" '"Bash(ls:*)"' "Common item present"
        # Check dedup: ls:* should appear exactly once
        local count
        count=$(echo "$result" | grep -c 'Bash(ls:\*)' || true)
        assert_eq "1" "$count" "Duplicate list items should be deduped"
    )
}

test_overlay_new_keys_added() {
    (
        echo '{"existing":"yes"}' > "$TEST_TMPDIR/base.json"
        echo '{"brand_new":"added"}' > "$TEST_TMPDIR/overlay.json"

        local result
        result=$(python3 "$JSON_OVERLAY" "$TEST_TMPDIR/base.json" "$TEST_TMPDIR/overlay.json")
        assert_contains "$result" '"existing": "yes"' "Base key preserved"
        assert_contains "$result" '"brand_new": "added"' "New overlay key added"
    )
}

test_overlay_base_only_keys_preserved() {
    (
        echo '{"base_key":"value","shared":"base"}' > "$TEST_TMPDIR/base.json"
        echo '{"shared":"overlay"}' > "$TEST_TMPDIR/overlay.json"

        local result
        result=$(python3 "$JSON_OVERLAY" "$TEST_TMPDIR/base.json" "$TEST_TMPDIR/overlay.json")
        assert_contains "$result" '"base_key": "value"' "Base-only key preserved"
        assert_contains "$result" '"shared": "overlay"' "Shared key uses overlay value"
    )
}

test_overlay_invalid_json_fails() {
    (
        echo '{"valid":"json"}' > "$TEST_TMPDIR/base.json"
        echo 'not json at all' > "$TEST_TMPDIR/overlay.json"

        local rc=0
        python3 "$JSON_OVERLAY" "$TEST_TMPDIR/base.json" "$TEST_TMPDIR/overlay.json" >/dev/null 2>&1 || rc=$?
        assert_neq "0" "$rc" "Invalid JSON should cause non-zero exit"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# deploy_settings integration tests
# ══════════════════════════════════════════════════════════════════════════════

test_deploy_no_overlay_unchanged() {
    (
        local repo="$TEST_TMPDIR/repo"
        local live_dir="$TEST_TMPDIR/cc-mirror/config"
        mkdir -p "$repo/setup/config" "$repo/setup/scripts" "$live_dir" "$repo/global/hooks"
        cp "$REPO_ROOT/global/hooks/lib-portable.sh" "$repo/global/hooks/"

        # Base settings
        cat > "$repo/setup/config/settings.json" <<'EOF'
{
  "env": {"A": "1"},
  "permissions": {"allow": ["Bash(git:*)"]},
  "hooks": {},
  "statusLine": {},
  "spinnerTipsEnabled": false,
  "enabledPlugins": {}
}
EOF

        # Existing live settings (for merge)
        cat > "$live_dir/settings.json" <<'EOF'
{
  "env": {"A": "1"},
  "permissions": {"allow": ["Bash(git:*)"]},
  "hooks": {},
  "statusLine": {},
  "spinnerTipsEnabled": false,
  "enabledPlugins": {}
}
EOF

        # Copy json-merge.py to repo
        cp "$REPO_ROOT/setup/scripts/json-merge.py" "$repo/setup/scripts/"
        cp "$REPO_ROOT/setup/scripts/json-overlay.py" "$repo/setup/scripts/" 2>/dev/null || true

        # Set up environment
        SCRIPT_DIR="$repo"
        GLOBAL_DIR="$repo/global"
        CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror"
        MACHINE_OVERRIDE="randombox:user"

        # Stubs
        log_info()  { :; }
        log_warn()  { echo "WARN: $*" >&2; }
        log_error() { echo "ERROR: $*" >&2; }

        # settings.json carries secrets in env: a deploy must keep its 600 (iv-agent-fleet #1, CFG-855)
        chmod 644 "$live_dir/settings.json"   # a file an earlier deploy loosened gets re-tightened
        source "$COMMON_SH"
        source "$DEPLOY_SH"
        deploy_settings

        # Check that live settings don't contain unexpected keys
        assert_file_exists "$live_dir/settings.json"
        assert_file_not_contains "$live_dir/settings.json" "powershell"
        assert_eq "600" "$(stat -c '%a' "$live_dir/settings.json")" "deploy keeps settings.json mode 600"
    )
}

test_deploy_with_overlay_merges_machine_keys() {
    (
        local repo="$TEST_TMPDIR/repo"
        local live_dir="$TEST_TMPDIR/cc-mirror/config"
        mkdir -p "$repo/setup/config/machines/wsl" "$repo/setup/scripts" \
                 "$live_dir" "$repo/global/hooks"
        cp "$REPO_ROOT/global/hooks/lib-portable.sh" "$repo/global/hooks/"

        # Base settings
        cat > "$repo/setup/config/settings.json" <<'EOF'
{
  "env": {"BASE_VAR": "base"},
  "permissions": {"allow": ["Bash(git:*)"]},
  "hooks": {},
  "statusLine": {},
  "spinnerTipsEnabled": false,
  "enabledPlugins": {}
}
EOF

        # WSL overlay
        cat > "$repo/setup/config/machines/wsl/settings.json" <<'EOF'
{
  "env": {"TERM_PROGRAM": ""},
  "permissions": {"allow": ["Bash(powershell.exe:*)", "Bash(wslpath:*)"]}
}
EOF

        # Existing live settings
        cat > "$live_dir/settings.json" <<'EOF'
{
  "env": {"BASE_VAR": "base"},
  "permissions": {"allow": ["Bash(git:*)"]},
  "hooks": {},
  "statusLine": {},
  "spinnerTipsEnabled": false,
  "enabledPlugins": {}
}
EOF

        # Copy required scripts
        cp "$REPO_ROOT/setup/scripts/json-merge.py" "$repo/setup/scripts/"
        cp "$REPO_ROOT/setup/scripts/json-overlay.py" "$repo/setup/scripts/" 2>/dev/null || true

        SCRIPT_DIR="$repo"
        GLOBAL_DIR="$repo/global"
        CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror"
        MACHINE_OVERRIDE="winbox-test:alice"
        write_fixture_map "$repo"

        log_info()  { :; }
        log_warn()  { echo "WARN: $*" >&2; }
        log_error() { echo "ERROR: $*" >&2; }

        source "$COMMON_SH"
        source "$DEPLOY_SH"
        deploy_settings

        # Verify overlay permissions were merged in
        assert_file_exists "$live_dir/settings.json"
        assert_file_contains "$live_dir/settings.json" "powershell"
        assert_file_contains "$live_dir/settings.json" "wslpath"
        # Base permission should still be there
        assert_file_contains "$live_dir/settings.json" "Bash(git:\*)"
    )
}

test_deploy_overlay_permissions_unioned() {
    (
        local repo="$TEST_TMPDIR/repo"
        local live_dir="$TEST_TMPDIR/cc-mirror/config"
        mkdir -p "$repo/setup/config/machines/wsl" "$repo/setup/scripts" \
                 "$live_dir" "$repo/global/hooks"
        # Copy lib-portable.sh so _to_native_path is available
        cp "$REPO_ROOT/global/hooks/lib-portable.sh" "$repo/global/hooks/"

        # Base with several permissions
        cat > "$repo/setup/config/settings.json" <<'EOF'
{
  "env": {},
  "permissions": {"allow": ["Bash(git:*)", "Bash(ls:*)", "Bash(cat:*)"]},
  "hooks": {},
  "statusLine": {},
  "spinnerTipsEnabled": false,
  "enabledPlugins": {}
}
EOF

        # Overlay adds some, overlaps on ls
        cat > "$repo/setup/config/machines/wsl/settings.json" <<'EOF'
{
  "permissions": {"allow": ["Bash(ls:*)", "Bash(cmd.exe:*)"]}
}
EOF

        # Live starts same as base
        cat > "$live_dir/settings.json" <<'EOF'
{
  "env": {},
  "permissions": {"allow": ["Bash(git:*)", "Bash(ls:*)", "Bash(cat:*)"]},
  "hooks": {},
  "statusLine": {},
  "spinnerTipsEnabled": false,
  "enabledPlugins": {}
}
EOF

        cp "$REPO_ROOT/setup/scripts/json-merge.py" "$repo/setup/scripts/"
        cp "$REPO_ROOT/setup/scripts/json-overlay.py" "$repo/setup/scripts/" 2>/dev/null || true

        SCRIPT_DIR="$repo"
        GLOBAL_DIR="$repo/global"
        CC_MIRROR_DIR="$TEST_TMPDIR/cc-mirror"
        MACHINE_OVERRIDE="winbox-test:alice"
        write_fixture_map "$repo"

        log_info()  { :; }
        log_warn()  { echo "WARN: $*" >&2; }
        log_error() { echo "ERROR: $*" >&2; }

        source "$COMMON_SH"
        source "$DEPLOY_SH"
        deploy_settings

        # All four unique permissions should be present
        assert_file_contains "$live_dir/settings.json" "Bash(git:\*)"
        assert_file_contains "$live_dir/settings.json" "Bash(ls:\*)"
        assert_file_contains "$live_dir/settings.json" "Bash(cat:\*)"
        assert_file_contains "$live_dir/settings.json" "Bash(cmd.exe:\*)"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# status overlay reporting test
# ══════════════════════════════════════════════════════════════════════════════

test_status_reports_machine_overlay() {
    (
        local repo="$TEST_TMPDIR/repo"
        mkdir -p "$repo/setup/config/machines/wsl" "$repo/global" \
                 "$repo/setup/projects" "$repo/cross-project"
        echo '{}' > "$repo/setup/config/machines/wsl/settings.json"

        SCRIPT_DIR="$repo"
        GLOBAL_DIR="$repo/global"
        PROJECTS_DIR="$repo/setup/projects"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        mkdir -p "$CLAUDE_HOME"
        PLATFORM="wsl"
        MACHINE_OVERRIDE="winbox-test:alice"
        write_fixture_map "$repo"
        RED='' YELLOW='' NC='' GREEN=''

        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        find_project_path() { echo ""; }

        source "$COMMON_SH"
        source "$REPO_ROOT/sync-lib/status.sh"

        local output
        output=$(cmd_status 2>&1)
        assert_contains "$output" "Machine overlay: wsl" "Status should report active machine overlay"
    )
}

test_status_reports_no_overlay_for_unknown() {
    (
        local repo="$TEST_TMPDIR/repo"
        mkdir -p "$repo/setup/config" "$repo/global" \
                 "$repo/setup/projects" "$repo/cross-project"

        SCRIPT_DIR="$repo"
        GLOBAL_DIR="$repo/global"
        PROJECTS_DIR="$repo/setup/projects"
        CLAUDE_HOME="$TEST_TMPDIR/claude-home"
        mkdir -p "$CLAUDE_HOME"
        PLATFORM="linux"
        MACHINE_OVERRIDE="randombox:user"
        RED='' YELLOW='' NC='' GREEN=''

        log_info()  { echo "[INFO] $*"; }
        log_warn()  { echo "[WARN] $*"; }
        find_project_path() { echo ""; }

        source "$COMMON_SH"
        source "$REPO_ROOT/sync-lib/status.sh"

        local output
        output=$(cmd_status 2>&1)
        assert_contains "$output" "Machine overlay: none" "Status should report none for unknown machine"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# pre-deploy JSON validation for machine overlay dirs
# ══════════════════════════════════════════════════════════════════════════════

test_predeploy_validates_overlay_json() {
    (
        local repo="$TEST_TMPDIR/repo"
        mkdir -p "$repo/global/hooks" "$repo/setup/config/machines/wsl"
        echo '{}' > "$repo/setup/config/settings.json"
        echo 'INVALID JSON' > "$repo/setup/config/machines/wsl/settings.json"

        SCRIPT_DIR="$repo"
        GLOBAL_DIR="$repo/global"
        SETUP_DIR="$repo/setup"

        log_info()  { :; }
        log_warn()  { :; }
        log_error() { echo "ERROR: $*" >&2; }

        source "$PRE_DEPLOY_SH"
        local rc=0
        pre_deploy_checks 2>/dev/null || rc=$?
        assert_neq "0" "$rc" "Should fail on invalid JSON in machine overlay dir"
    )
}

test_predeploy_passes_valid_overlay_json() {
    (
        local repo="$TEST_TMPDIR/repo"
        mkdir -p "$repo/global/hooks" "$repo/setup/config/machines/wsl"
        echo '{}' > "$repo/setup/config/settings.json"
        echo '{"env":{}}' > "$repo/setup/config/machines/wsl/settings.json"

        SCRIPT_DIR="$repo"
        GLOBAL_DIR="$repo/global"
        SETUP_DIR="$repo/setup"

        log_info()  { :; }
        log_warn()  { :; }
        log_error() { echo "ERROR: $*" >&2; }

        source "$PRE_DEPLOY_SH"
        local rc=0
        pre_deploy_checks 2>/dev/null || rc=$?
        assert_eq "0" "$rc" "Should pass with valid JSON in machine overlay dir"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# Directory structure tests
# ══════════════════════════════════════════════════════════════════════════════

test_overlay_dirs_exist() {
    # Every overlay the real map names must exist as a directory. No map (template) → skip.
    local conf="$REPO_ROOT/setup/config/machines/machine-map.conf" line key dir
    if [[ ! -f "$conf" ]]; then
        echo "  SKIP: no machine-map.conf"; return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        read -r key dir _ <<< "$line"
        [[ -z "$key" || -z "$dir" ]] && continue
        assert_dir_exists "$REPO_ROOT/setup/config/machines/$dir" \
            "Machine overlay dir $dir (named in machine-map.conf) should exist"
    done < "$conf"
}

test_deploy_absent_config_dir_warns() {
    (
        local repo="$TEST_TMPDIR/absent"
        mkdir -p "$repo/setup/config" "$repo/setup/scripts" "$repo/global/hooks"
        cp "$REPO_ROOT/global/hooks/lib-portable.sh" "$repo/global/hooks/"
        echo '{"env":{},"hooks":{}}' > "$repo/setup/config/settings.json"
        SCRIPT_DIR="$repo"
        GLOBAL_DIR="$repo/global"
        CC_MIRROR_DIR="$TEST_TMPDIR/no-such-mirror"
        MACHINE_OVERRIDE="randombox:user"
        log_info()  { :; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERROR: $*"; }
        source "$COMMON_SH"
        source "$DEPLOY_SH"
        local out rc
        out=$(set -e; deploy_settings 2>&1); rc=$?
        assert_eq "0" "$rc" "absent cc-mirror config dir must not fail the deploy (rc=$rc)"
        assert_contains "$out" "WARN" "absent config dir is reported"
        assert_file_not_exists "$TEST_TMPDIR/no-such-mirror/config/settings.json" "nothing is written"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
# Run all tests
# ══════════════════════════════════════════════════════════════════════════════

# detect_machine_dir
run_test "detect_machine_dir: winbox hostname → wsl" test_detect_wsl
run_test "detect_machine_dir: handheld → steamos" test_detect_steamos_handheld
run_test "detect_machine_dir: console → steamos" test_detect_steamos_console
run_test "detect_machine_dir: ws + alice → fedora-home" test_detect_fedora_home
run_test "detect_machine_dir: ws + bob → office" test_detect_office
run_test "detect_machine_dir: cloudhost → vps" test_detect_vps
run_test "detect_machine_dir: homeserver + alice → nuc" test_detect_nuc
run_test "detect_machine_dir: corpbook + carol → ivbook" test_detect_ivbook
run_test "detect_machine_dir: corpbook + other user → empty" test_detect_ivbook_wrong_user
run_test "machine-map: first match wins" test_map_first_match_wins
run_test "machine-map: comments/blank lines ignored" test_map_ignores_comments_and_blank_lines
run_test "machine-map: FLEET_MACHINE beats map" test_fleet_machine_env_beats_map
run_test "machine-map: MACHINE_OVERRIDE beats FLEET_MACHINE" test_machine_override_beats_fleet_machine
run_test "machine-map: local_machine_map fallback" test_local_machine_map_fallback
run_test "machine-map: no map, no hook → empty" test_no_map_no_hook_is_empty
run_test "machine-map: .example ships and parses" test_map_example_ships_and_parses
run_test "machine-map: real conf resolves fleet (personal-only)" test_real_map_resolves_fleet
run_test "detect_machine_dir: unknown → empty" test_detect_unknown
run_test "detect_machine_dir: MACHINE_OVERRIDE works" test_detect_machine_override_env

# resolve_config_file
run_test "resolve_config_file: returns overlay when exists" test_resolve_returns_overlay_when_exists
run_test "resolve_config_file: returns base when no overlay" test_resolve_returns_base_when_no_overlay
run_test "resolve_config_file: returns base for unknown machine" test_resolve_returns_base_for_unknown_machine
run_test "resolve_config_file: returns empty when neither exists" test_resolve_returns_empty_when_neither_exists

# json-overlay.py
run_test "json-overlay.py: empty overlay = base unchanged" test_overlay_empty_overlay_returns_base
run_test "json-overlay.py: scalar override" test_overlay_scalar_override
run_test "json-overlay.py: nested dict merge" test_overlay_nested_dict_merge
run_test "json-overlay.py: list union (permissions.allow)" test_overlay_list_union
run_test "json-overlay.py: new keys added" test_overlay_new_keys_added
run_test "json-overlay.py: base-only keys preserved" test_overlay_base_only_keys_preserved
run_test "json-overlay.py: invalid JSON fails" test_overlay_invalid_json_fails

# deploy_settings integration
run_test "deploy_settings: no overlay = unchanged" test_deploy_no_overlay_unchanged
run_test "deploy_settings: with overlay = machine keys appear" test_deploy_with_overlay_merges_machine_keys
run_test "deploy_settings: overlay permissions unioned with base" test_deploy_overlay_permissions_unioned
run_test "deploy_settings: absent cc-mirror config dir → warn, write nothing, rc 0" test_deploy_absent_config_dir_warns

# status reporting
run_test "cmd_status: reports active machine overlay" test_status_reports_machine_overlay
run_test "cmd_status: reports none for unknown machine" test_status_reports_no_overlay_for_unknown

# pre-deploy validation
run_test "pre_deploy_checks: validates JSON in machine overlay dirs" test_predeploy_validates_overlay_json
run_test "pre_deploy_checks: passes valid overlay JSON" test_predeploy_passes_valid_overlay_json

# directory structure
run_test "overlay dirs exist for every mapped machine" test_overlay_dirs_exist

suite_summary
