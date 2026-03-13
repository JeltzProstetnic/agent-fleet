Action: act

# Fresh Install UX Fixes (AFT-42..46)

From 2026-03-13 deployment test on WSL. Session fixed critical blockers (nvm, missing sync.sh setup, registry guards). These cosmetic/UX issues remain:

## AFT-42: Mangled logo
AF banner + CC built-in banner overlap. CC_MIRROR_SPLASH=0 only suppresses mclaude splash. Need hideStartupBanner tweak or alternative.

## AFT-43: Tips still showing
settings.json has CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 but tips appear. Verify settings.json deployment path matches what CC reads for mclaude variant (~/.cc-mirror/mclaude/config/settings.json).

## AFT-44: CRI/statusline not showing
statusline-command.sh deployed by configure-claude.sh. statusLine block in settings.json may not be picked up. Same root cause as AFT-43 likely.

## AFT-45: Network fetch failure message
git-sync-check says "offline or unreachable" when origin remote doesn't exist (install.sh renamed to upstream). Should say "no remote configured yet".

## AFT-46: First-run onboarding passive
Agent says "What are you working on?" instead of guiding setup. Check .setup-pending marker, config-check hook detection, first-run-refinement.md content.

## Also pending
- Propagate sync.sh and git-sync-check.sh fixes to cfg-agent-fleet
- Spinner below statusline issue (deferred)
