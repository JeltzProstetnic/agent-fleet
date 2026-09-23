#!/usr/bin/env bash
# lib-cc-install-fixture.sh — build a fake cc-mirror install under the sandboxed $HOME.
#
# Shared by test-cc-install-invariants.sh, test-cc-update-guard.sh, test-check-cc-install.sh
# and test-runbook-cc-update.sh. Source AFTER test-helpers.sh (needs TEST_TMPDIR and a
# sandboxed HOME). Named lib-* on purpose: run.sh executes test-*.sh only.
#
# Background (2026-09-23 incident, WSL): the documented `cc-mirror update mclaude
# --claude-version latest --no-tweak` resolved to a stale cc-mirror 1.6.2 on the Windows
# npm PATH, which does not know --claude-version, re-provisioned from variant.json's
# creation-time pin (claudeOrig = 2.1.1), rewrote the launcher to `exec node .../cli.js`,
# re-asserted teamModeEnabled=true and reinstalled the orchestration/task-manager skills.
# It exited 0. Nothing in the fleet compared the install against what it had been.
# These fixtures reproduce every one of those shapes so the guards can be specified.

# make_cc_mirror_fixture <mirror_dir> <launcher> <installed_version> <declared_range> <team_mode> [layout]
#   layout: npm (default) — WSL/VPS shape: npm/package.json + node_modules/.../bin/claude.exe
#           native         — Deck/NUC/office shape: native/claude only, no npm/ at all
make_cc_mirror_fixture() {
    local mirror="$1" launcher="$2" version="$3" range="$4" team="$5" layout="${6:-npm}"
    local pkg_dir="$mirror/npm/node_modules/@anthropic-ai/claude-code"
    local binary

    mkdir -p "$mirror/config/skills/lrn" "$mirror/config/skills/simopt" "$mirror/tweakcc" \
             "$(dirname "$launcher")"
    printf '# lrn\n' > "$mirror/config/skills/lrn/SKILL.md"
    printf '# simopt\n' > "$mirror/config/skills/simopt/SKILL.md"
    printf '{\n  "env": {\n    "DISABLE_AUTOUPDATER": "1"\n  },\n  "hooks": {}\n}\n' \
        > "$mirror/config/settings.json"

    if [[ "$layout" == "npm" ]]; then
        mkdir -p "$pkg_dir/bin"
        printf '{\n  "dependencies": {\n    "@anthropic-ai/claude-code": "%s"\n  }\n}\n' "$range" \
            > "$mirror/npm/package.json"
        printf '{\n  "name": "@anthropic-ai/claude-code",\n  "version": "%s"\n}\n' "$version" \
            > "$pkg_dir/package.json"
        binary="$pkg_dir/bin/claude.exe"
        _fixture_version_stub "$binary" "$version"
        cat > "$mirror/variant.json" <<EOF
{
  "name": "mclaude",
  "provider": "mirror",
  "createdAt": "2026-02-09T13:00:35.788Z",
  "claudeOrig": "npm:@anthropic-ai/claude-code@2.1.1",
  "binaryPath": "$binary",
  "configDir": "$mirror/config",
  "tweakDir": "$mirror/tweakcc",
  "skillInstall": true,
  "installType": "npm",
  "npmDir": "$mirror/npm",
  "npmPackage": "@anthropic-ai/claude-code",
  "npmVersion": "$version",
  "teamModeEnabled": $team,
  "updatedAt": "2026-08-02T20:17:20.000Z"
}
EOF
    else
        mkdir -p "$mirror/native"
        binary="$mirror/native/claude"
        _fixture_version_stub "$binary" "$version"
        cat > "$mirror/variant.json" <<EOF
{
  "name": "mclaude",
  "provider": "mirror",
  "createdAt": "2026-02-09T13:00:35.788Z",
  "claudeOrig": "native:$version",
  "binaryPath": "$binary",
  "configDir": "$mirror/config",
  "tweakDir": "$mirror/tweakcc",
  "skillInstall": true,
  "installType": "native",
  "nativeDir": "$mirror/native",
  "nativeVersion": "latest",
  "nativeVersionSource": "default",
  "teamModeEnabled": $team,
  "updatedAt": "2026-08-02T20:17:20.000Z"
}
EOF
    fi

    cat > "$launcher" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_CONFIG_DIR="$mirror/config"
export TWEAKCC_CONFIG_DIR="$mirror/tweakcc"
# Run Claude Code
exec "$binary" "\$@"
EOF
    chmod +x "$launcher"
}

# A stand-in binary: answers --version like the real one ("X.Y.Z (Claude Code)").
_fixture_version_stub() {
    local path="$1" version="$2"
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == "--version" ]] && { echo "%s (Claude Code)"; exit 0; }\nexit 1\n' \
        "$version" > "$path"
    chmod +x "$path"
}

# fixture_set_launcher_target <launcher> <target> [node]
#   Rewrites the exec line the way cc-mirror 1.6.2 did today: `exec node "<cli.js>"`.
fixture_set_launcher_target() {
    local launcher="$1" target="$2" prefix="${3:-}"
    local tmp="$launcher.tmp"
    head -n -1 "$launcher" > "$tmp"
    if [[ "$prefix" == "node" ]]; then
        printf 'exec node "%s" "$@"\n' "$target" >> "$tmp"
    else
        printf 'exec "%s" "$@"\n' "$target" >> "$tmp"
    fi
    mv "$tmp" "$launcher"
    chmod +x "$launcher"
}

# fixture_add_skill <mirror_dir> <name>   — what team mode re-provisioning drops in
fixture_add_skill() {
    mkdir -p "$1/config/skills/$2"
    printf '# %s\n' "$2" > "$1/config/skills/$2/SKILL.md"
}

# fixture_settings_env <mirror_dir> KEY VALUE — add an env key to the LIVE settings.json
fixture_settings_env() {
    python3 - "$1/config/settings.json" "$2" "$3" <<'PY'
import json, sys
p, k, v = sys.argv[1:4]
d = json.load(open(p))
d.setdefault("env", {})[k] = v
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
}

# fixture_set_variant_field <mirror_dir> KEY JSON_VALUE — e.g. teamModeEnabled true
fixture_set_variant_field() {
    python3 - "$1/variant.json" "$2" "$3" <<'PY'
import json, sys
p, k, raw = sys.argv[1:4]
d = json.load(open(p))
d[k] = json.loads(raw)
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
}

# make_settings_template <path> [KEY VALUE ...] — the repo-side settings.json stand-in
make_settings_template() {
    local path="$1"; shift
    mkdir -p "$(dirname "$path")"
    python3 - "$path" "$@" <<'PY'
import json, sys
p = sys.argv[1]; kv = sys.argv[2:]
env = {"DISABLE_AUTOUPDATER": "1"}
for i in range(0, len(kv) - 1, 2):
    env[kv[i]] = kv[i + 1]
open(p, "w").write(json.dumps({"env": env, "hooks": {}}, indent=2) + "\n")
PY
}

# write_cc_snapshot <file> <version> <team_mode> [skills_csv]
#   The "last known good" record the guard compares against. key=value, one per line.
#   This format is part of the spec: hand-written by tests, machine-written by the guard.
write_cc_snapshot() {
    local file="$1" version="$2" team="$3" skills="${4:-lrn,simopt}"
    mkdir -p "$(dirname "$file")"
    printf 'version=%s\nteamModeEnabled=%s\nskills=%s\n' "$version" "$team" "$skills" > "$file"
}

# mock_npm <mockbin_dir> <marker_file> [view_version]
#   npm stand-in: touches <marker_file> on EVERY invocation (so a test can prove the
#   guard never went to the network); `npm view … version` prints <view_version>, or
#   exits 1 when none is given (network down). Everything else exits 0.
mock_npm() {
    local dir="$1" marker="$2" view="${3:-}"
    mkdir -p "$dir"
    cat > "$dir/npm" <<EOF
#!/usr/bin/env bash
touch "$marker"
if [[ "\${1:-}" == "view" ]]; then
    [[ -n "$view" ]] || exit 1
    echo "$view"
    exit 0
fi
exit 0
EOF
    chmod +x "$dir/npm"
}

# mock_cc_mirror_1_6_2 <mockbin_dir> <name> <marker_file> <mirror_dir> <launcher>
#   Reproduces what the stale cc-mirror did on 2026-09-23 when invoked as <name>
#   (either a bare `cc-mirror` on PATH or `npx`): ignores --claude-version, installs the
#   creation-time pin 2.1.1 as cli.js, points the launcher at it, re-asserts
#   teamModeEnabled=true, drops the orchestration + task-manager skills, exits 0.
mock_cc_mirror_1_6_2() {
    local dir="$1" name="$2" marker="$3" mirror="$4" launcher="$5"
    local pkg_dir="$mirror/npm/node_modules/@anthropic-ai/claude-code"
    mkdir -p "$dir"
    cat > "$dir/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$marker"
mkdir -p "$pkg_dir" "$mirror/config/skills/orchestration" "$mirror/config/skills/task-manager"
printf '{\n  "name": "@anthropic-ai/claude-code",\n  "version": "2.1.1"\n}\n' > "$pkg_dir/package.json"
printf '#!/usr/bin/env node\nconsole.log("2.1.1 (Claude Code)");\n' > "$pkg_dir/cli.js"
chmod +x "$pkg_dir/cli.js"
rm -f "$pkg_dir/bin/claude.exe"
python3 - "$mirror/variant.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["npmVersion"] = "2.1.1"; d["teamModeEnabled"] = True
d["binaryPath"] = "$pkg_dir/cli.js"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
head -n -1 "$launcher" > "$launcher.tmp"
printf 'exec node "%s" "\$@"\n' "$pkg_dir/cli.js" >> "$launcher.tmp"
mv "$launcher.tmp" "$launcher"; chmod +x "$launcher"
printf '# orchestration\n' > "$mirror/config/skills/orchestration/SKILL.md"
printf '# task-manager\n' > "$mirror/config/skills/task-manager/SKILL.md"
echo "Variant updated"
exit 0
EOF
    chmod +x "$dir/$name"
}

# mock_installer_ok <mockbin_dir> <name> <marker_file> <mirror_dir> <target_version>
#   A well-behaved installer stand-in (npm or npx): installs <target_version> with a
#   bin/claude.exe entry point and keeps npm/package.json's range in step. Records argv.
mock_installer_ok() {
    local dir="$1" name="$2" marker="$3" mirror="$4" target="$5"
    local pkg_dir="$mirror/npm/node_modules/@anthropic-ai/claude-code"
    mkdir -p "$dir"
    cat > "$dir/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$marker"
if [[ "\${1:-}" == "view" ]]; then echo "$target"; exit 0; fi
mkdir -p "$pkg_dir/bin"
printf '{\n  "name": "@anthropic-ai/claude-code",\n  "version": "%s"\n}\n' "$target" > "$pkg_dir/package.json"
printf '{\n  "dependencies": {\n    "@anthropic-ai/claude-code": "^%s"\n  }\n}\n' "$target" > "$mirror/npm/package.json"
printf '#!/usr/bin/env bash\n[[ "\${1:-}" == "--version" ]] && { echo "%s (Claude Code)"; exit 0; }\nexit 1\n' "$target" > "$pkg_dir/bin/claude.exe"
chmod +x "$pkg_dir/bin/claude.exe"
exit 0
EOF
    chmod +x "$dir/$name"
}
