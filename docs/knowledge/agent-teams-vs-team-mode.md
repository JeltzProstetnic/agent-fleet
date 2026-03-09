# Agent Teams vs TEAM_MODE

## Executive Summary

Two distinct orchestration models for multi-agent workflows. Pick one per use case — they don't conflict.

---

## TEAM_MODE (Current Default)

**Model:** Orchestrator + subagents within single session.

- **Execution**: Orchestrator agent spawns workers; all share context via session memory
- **Communication**: Workers report to orchestrator only (star topology)
- **Token cost**: Moderate — single session, consolidated context
- **Proven**: Stable and reliable for production use
- **Best for**: Sequential workflow with clear handoff points, coding tasks, focused research

**Enable** (in `settings.json` env section):
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
- **Status**: Experimental
- **Best for**: Large parallel research tasks, competing hypotheses, multi-perspective synthesis

**Enable** (in `settings.json` env section):
```json
{
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
}
```

Then restart Claude Code and request teams in conversation: *"Create a team of 3 researchers to investigate X from different angles."*

---

## Compatibility Matrix

| Scenario | TEAM_MODE | Agent Teams | Choice |
|----------|-----------|------------|--------|
| Sequential code implementation | Ideal | Overkill | **TEAM_MODE** |
| Focused paper editing | Ideal | Overkill | **TEAM_MODE** |
| Parallel research (competing views) | Works | Ideal | **Agent Teams** |
| Literature synthesis (5+ sources) | Works | Better | **Agent Teams** |
| Production systems | Stable | Experimental | **TEAM_MODE** |

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

## Configuration Reference

**To enable Agent Teams**, edit your Claude Code `settings.json` env section:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "TEAM_MODE": "1"
  }
}
```

Restart Claude Code, then in conversation: *"Spawn a team of 4 independent agents to research topic X."*
