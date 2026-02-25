# Agent Teams vs cc-mirror TEAM_MODE

## Executive Summary

Two distinct orchestration models for multi-agent workflows. Pick one per use case — they don't conflict.

---

## cc-mirror TEAM_MODE (Current Default)

**Model:** Orchestrator + subagents within single session.

- **Execution**: Orchestrator agent spawns workers; all share context via session memory
- **Communication**: Workers report to orchestrator only (star topology)
- **Token cost**: Moderate — single session, consolidated context
- **Proven**: ✅ Stable since Session 60, domain guides work reliably
- **Best for**: Sequential workflow with clear handoff points, coding tasks, focused research

**Enable:**
```json
{
  "TEAM_MODE": "1"
}
```

---

## Agent Teams (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)

**Model:** Multiple independent Claude Code sessions with peer-to-peer messaging.

- **Execution**: Each agent runs own session, own model instance
- **Communication**: Direct agent-to-agent messaging (mesh topology)
- **Token cost**: ~5x higher (multiple model instances running parallel)
- **Status**: ⚠️ Experimental (Feb 2026 release)
- **Best for**: Large parallel research tasks, competing hypotheses, multi-perspective synthesis

**Enable:**
```json
{
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
}
```

Then restart mclaude and request teams in conversation: *"Create a team of 3 researchers to investigate X from different angles."*

---

## Compatibility Matrix

| Scenario | TEAM_MODE | Agent Teams | Choice |
|----------|-----------|------------|--------|
| Sequential code implementation | ✅ Ideal | ❌ Overkill | **TEAM_MODE** |
| Focused paper editing | ✅ Ideal | ❌ Overkill | **TEAM_MODE** |
| Parallel research (competing views) | ⚠️ Works | ✅ Ideal | **Agent Teams** |
| Literature synthesis (5+ sources) | ⚠️ Works | ✅ Better | **Agent Teams** |
| Production systems | ✅ Stable | ❌ Experimental | **TEAM_MODE** |

**Can they coexist?** Yes. Both can be enabled. Request the one you need in conversation — Claude Code picks the right model.

---

## How Agent Teams Work (Technical)

1. User: *"Create a team of researchers to validate this hypothesis."*
2. Claude Code spawns N independent sessions (each own model, own context window)
3. Agents discover each other via mesh protocol
4. Agents exchange findings via async messaging
5. Orchestrator (user's session) receives synthesis summary
6. Cost: N × (session overhead + model time). Higher token burn.

**Advantage over TEAM_MODE:** Parallel research without orchestrator bottleneck. Each agent thinks independently then converges.

---

## Recommendation

- **Default**: Keep TEAM_MODE enabled for 95% of work (proven, cost-effective)
- **Experimental use**: Try Agent Teams for large parallel research where multiple independent perspectives add value
- **Not recommended**: Don't enable both simultaneously unless you explicitly request teams — context overhead

---

## Version Notes

- **Claude Code version**: 2.1.37 (latest: 2.1.47)
- **Agent Teams**: Available in 2.1.37+
- **TEAM_MODE**: Standard since 2.1.0
- **Tested**: Feb 2026

---

## Configuration Reference

**To enable Agent Teams**, edit `~/.cc-mirror/mclaude/config/settings.json`:

```json
{
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
  "TEAM_MODE": "1"
}
```

Restart mclaude:
```bash
mclaude
```

Then in conversation: *"Spawn a team of 4 independent agents to research topic X."*
