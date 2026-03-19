# Check group 7: Environment — settings & tools checks
# Checks: 19(plugins), 32(splash), 27(afleet), 28(TweakCC)
# Shared vars used: CONFIG_REPO, WARNINGS, SETTINGS_FILE
# Split from original 07-environment.sh; platform/docs/lock checks moved to 07b-platform-env.sh

# Check 19: Auto-disable global enabledPlugins (token budget protection)
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"enabledPlugins"' "$SETTINGS_FILE" 2>/dev/null; then
        _ep_tmp="$(mktemp)"
        printf '%s\n' 'import json,sys,os' 'f=sys.argv[1]' 'd=json.load(open(f))' 'ep=d.get("enabledPlugins",{})' 'n=len(ep)' 'if n>0:' '  d["enabledPlugins"]={}' '  t=f+".tmp"; open(t,"w").write(json.dumps(d,indent=2)+"\n"); os.rename(t,f)' 'print(n)' > "$_ep_tmp"
        _ep_count=$(python3 "$_ep_tmp" "$SETTINGS_FILE" 2>/dev/null || echo "0")
        rm -f "$_ep_tmp"
        if [ "$_ep_count" -gt 0 ]; then
            WARNINGS="${WARNINGS:+$WARNINGS | }Global enabledPlugins had $_ep_count plugin(s) — auto-disabled. Plugins consume ~10k tokens/bundle. Enable per-project only via .claude/settings.local.json."
        fi
    fi
fi

# Check 32: Auto-fix CC_MIRROR_SPLASH drift
if [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"CC_MIRROR_SPLASH"' "$SETTINGS_FILE" 2>/dev/null; then
        _splash_val=$(python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); print(d.get('env',{}).get('CC_MIRROR_SPLASH','0'))" 2>/dev/null || echo "0")
        if [ "$_splash_val" != "0" ]; then
            python3 -c "
import json, sys, os
f = sys.argv[1]
with open(f) as fh: d = json.load(fh)
if 'env' in d and 'CC_MIRROR_SPLASH' in d['env']:
    d['env']['CC_MIRROR_SPLASH'] = '0'
    t = f + '.tmp'
    with open(t, 'w') as fh: json.dump(d, fh, indent=2); fh.write('\n')
    os.rename(t, f)
" "$SETTINGS_FILE" 2>/dev/null || true
        fi
    fi
fi

# Check 27: afleet mandatory — warn if launched directly via mclaude
if [[ -z "${AFLEET_LAUNCHED:-}" ]]; then
    WARNINGS="${WARNINGS:+$WARNINGS | }Session NOT launched via afleet. Use 'afleet' instead of 'mclaude' — afleet handles pre-pull, project detection, and session safety. Direct mclaude launch skips fleet infrastructure."
fi

# Check 28: TweakCC stale patch detection
CC_MIRROR_DIR="${CC_MIRROR_DIR:-$HOME/.cc-mirror/mclaude}"
TWEAKCC_CONFIG="$CC_MIRROR_DIR/tweakcc/config.json"
CC_PACKAGE="$CC_MIRROR_DIR/npm/node_modules/@anthropic-ai/claude-code/package.json"
if [ -f "$TWEAKCC_CONFIG" ] && [ -f "$CC_PACKAGE" ]; then
    _tweak_ver=$(python3 -c "import json; print(json.load(open('$TWEAKCC_CONFIG')).get('ccVersion',''))" 2>/dev/null || true)
    _tweak_applied=$(python3 -c "import json; print(json.load(open('$TWEAKCC_CONFIG')).get('changesApplied',True))" 2>/dev/null || true)
    _cc_ver=$(python3 -c "import json; print(json.load(open('$CC_PACKAGE')).get('version',''))" 2>/dev/null || true)
    if [ -n "$_tweak_ver" ] && [ -n "$_cc_ver" ] && [ "$_tweak_ver" != "$_cc_ver" ] && [ "$_tweak_applied" = "False" ]; then
        WARNINGS="${WARNINGS:+$WARNINGS | }TweakCC patches stale (applied to $_tweak_ver, installed CC is $_cc_ver) — run \`cc-mirror tweak mclaude\` from interactive terminal."
    fi
fi
