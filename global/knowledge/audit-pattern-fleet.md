# P4: Deep Multi-Agent Fleet Self-Audit — Orchestration Guide

**Loaded on demand when P4 is triggered. Not loaded at every audit.**

## What This Pattern Does

Deploys 4 Opus subagents across 3 phases to audit the entire agent fleet system — not just one project, but the interactions between projects, the propagation chain, deployed state, and broader infrastructure (DMS, AFD, vault, MCP).

## When to Use

- After major structural changes (file moves, module extraction, new sync mechanisms)
- Periodic fleet health check (monthly recommended)
- When a P2/P3 audit on one project reveals cross-project issues
- After multi-day unsupervised work spanning multiple repos
- When propagation drift warnings accumulate across sessions

## When NOT to Use

- Routine post-session checks (use P1)
- Single-project investigations (use P2 or P3)
- Quick "did the deploy work?" verification (use P1)
- When context budget is >60% used (agents need room — recommend `/clear` first)

## How It Works

### Phase 1: Parallel Per-Project Audits (2 agents, concurrent)

Launch two Opus agents simultaneously:

**Agent 1 — Config repo (your private fork):**
- All bash scripts: path references (REPO_DIR, SCRIPT_DIR, source statements)
- Full test suite execution (`bash setup/tests/run.sh`)
- Cross-references in docs (stale paths, wrong filenames)
- Symlink integrity (`sync.sh status`, `~/.claude/` symlinks)
- Git state (uncommitted changes, untracked files, gitignore correctness)
- Configuration health (settings.json valid, .mcp.json valid)
- Script executability (+x permissions)
- Sync-lib extraction integrity

**Agent 2 — Template repo (agent-fleet):**
- Same script/path/test checks as Agent 1
- **Template cleanliness** (personal data leaks — grep for personal names, emails, hostnames, org names)
- Documentation accuracy (README matches actual structure)
- Gitignore completeness
- No personal config leaked into template

### Phase 2: Cross-Project Audit (1 agent, after Phase 1)

Feed Phase 1 findings into prompt context. Agent checks:

- **File parity**: `diff` corresponding files between repos. Classify differences as (a) expected personalization, (b) propagation miss, (c) unclear
- **Manifest accuracy**: Is `template-sync-manifest.md` "Must Be Identical" list actually identical?
- **Propagation chain**: Are inbox items for the other repo executed?
- **Registry consistency**: Do listed projects exist on disk?
- **Deployed vs repo**: Are `~/.claude/` files symlinked or stale copies?
- **Session state**: Stale handoffs, broken references?
- **Broader fleet**: DMS (exists, tests pass?), AFD (exists, deployable?), vault (encrypted file present?), MCP (valid JSON?), skills (installed?)

### Phase 3: Meta-Analysis (1 agent, after Phase 2)

Feed ALL prior findings. Agent produces:

- **Deduplication**: Merge findings across all three agents
- **Blind spot analysis**: What did nobody check?
- **Audit quality assessment**: Coverage %, depth rating, false positive risk
- **Priority classification**: P0/P1/P2/P3 with effort estimates (S/M/L/XL)
- **Action plan**: Single-session or multi-session, with dependency ordering
- **Output**: Pending file (`docs/pending-deep-audit-YYYY-MM-DD.md`) with `Action: act`

## Dos and Don'ts

**Do:**
- Run `/clear` before starting if context budget >50%
- Include prior audit findings in Phase 2/3 prompts (avoid re-discovery)
- Let agents run in background — they take 5-10 min each
- Commit fixes from the current session BEFORE launching agents (they read repo state)
- Save agent outputs to files immediately (conversation context dies with session)

**Don't:**
- Don't duplicate agent work in the main session while they run
- Don't launch Phase 2 before both Phase 1 agents complete
- Don't fix findings during the audit — the audit produces the plan, execution is separate
- Don't use haiku agents for this — the cross-referencing and judgment calls need Opus
- Don't skip Phase 3 — blind spot analysis is the highest-value step

## Expected Results

From the inaugural run (2026-03-14):
- 55 raw findings → 33 unique after dedup
- 14 blind spots identified
- ~40% codebase coverage
- 4 P0, 9 P1, 17 P2, 4 P3
- 3-session fix plan (~8-12 hours)
- Total agent cost: ~400k tokens across 4 agents

## Improving This Pattern

After each run, check:
1. Were there findings that a cheaper pattern (P1-P3) should have caught earlier?
2. Were there blind spots that should be added to the agent prompts?
3. Was the Phase 3 meta-analysis accurate? Did it miss things or over-count?
4. Could any agent be replaced with a haiku agent without quality loss?
