Action: act

# E2E Onboarding Test — Ready to Execute

## Test VM
- **Distro:** Ubuntu-24.04 (WSL2 instance, `wsl -d Ubuntu-24.04 -u aftest`)
- **User:** aftest (sudo NOPASSWD)
- **State:** agent-fleet cloned, setup.sh completed, all symlinks + hooks deployed, `.setup-pending` present
- **Cleanup:** `wsl --unregister Ubuntu-24.04` when done

## Step 1: Run E2E onboarding test
Pass API key and launch:
```bash
wsl -d Ubuntu-24.04 -u aftest
export ANTHROPIC_API_KEY="<key>"
source ~/.bashrc
afleet
```
Observe: Does onboarding trigger? Does the agent ask the right questions? Does it write config files correctly?

## Step 2: Bugs found during VM setup (fix in agent-fleet)
1. **install-skill-collections.sh writes to global enabledPlugins** — should write to per-project settings.local.json. Hook auto-disables (so new users aren't broken), but the install flow is wrong. Fix: change Step 3 in the script to NOT merge into global settings.json.
2. **Phase 2 (configure-claude.sh) failed on first run** — succeeded on retry. Likely NVM not loaded in non-interactive shell context. The `ensure_tool_paths` function may need a more aggressive NVM detection for the first-run case inside install.sh's orchestrated flow.

## Step 3: Pending template propagation (from inbox)
- Scrollback fix: remove `CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL` and `TERM_PROGRAM_INHIBIT_ALTSCREEN` from settings.json env, fix afleet.sh clear sequences, rewrite scrollback test
- LRN fix: add `~/.claude/CLAUDE.md` to Process agent reading list in learn-protocol.md
