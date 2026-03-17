# AIOS Memory System Design -- Reference Architecture

A knowledge graph-based memory system for AI agents, based on a four-model consciousness theory. This documents a design pattern for structured agent memory that goes beyond flat-file session persistence.

## Theoretical Foundation

Based on a Four-Model Theory of consciousness:

| Model | Nature | Maps to Agent System |
|-------|--------|---------------------|
| Self-Model | Implicit, learned, never conscious | LLM weights + system config + behavioral patterns |
| Meta-Model | Implicit total knowledge | SQLite knowledge graph (persistent) |
| I-Model | Explicit self-description, conscious | Self-entity subgraph (traversable from SELF anchor) |
| World-Model | Explicit simulation, transient | Assembled LLM context window per turn |
| Working Model | Active subset of World+I-Model | Short-term conversation buffer |

Key insight: The context window IS the World-Model -- a transient simulation assembled from the persistent Meta-Model (knowledge graph) for each turn.

## Three-Tier Memory Architecture

| Tier | Name | Persistence | Duration | Agent-Fleet Analog |
|------|------|-------------|----------|-------------------|
| Short-term | Working Model | In-memory only | Seconds-minutes | Context window |
| Medium-term | -- | SQLite | Hours-days (30d default) | session-context.md + session-history.md |
| Long-term | Meta-Model | SQLite knowledge graph | Days-years | CLAUDE.md + knowledge files + auto-memory |

Consolidation is **experience-driven**, not clock-driven:
- Short -> Medium: buffer overflow, session end
- Medium -> Long: fact reinforcement, user correction, medium overflow
- Long -> decay: importance drops without access

## SQLite Schema

### Entities
```sql
CREATE TABLE entities (
    id TEXT PRIMARY KEY,          -- UUID
    label TEXT NOT NULL,          -- "User", "RTX 4090"
    created_at DATETIME,
    updated_at DATETIME,
    last_accessed DATETIME,       -- for importance decay
    importance REAL DEFAULT 0.5,  -- 0.0-1.0, decays without access
    confidence REAL DEFAULT 0.5,  -- 0.0-1.0
    source TEXT                   -- "conversation", "onboarding", "observation"
);
```

No fixed types -- types emerge from relations (`is_a -> Person`), not from a type column.

### Entity Properties (EAV)
```sql
CREATE TABLE entity_properties (
    entity_id TEXT REFERENCES entities(id),
    key TEXT,
    value TEXT  -- JSON for complex types
);
```

### Relations
```sql
CREATE TABLE relations (
    id TEXT PRIMARY KEY,
    source_id TEXT REFERENCES entities(id),
    target_id TEXT REFERENCES entities(id),
    created_at DATETIME,
    updated_at DATETIME,
    confidence REAL DEFAULT 0.5,
    source_info TEXT              -- "conversation:2026-02-12", "inferred"
);
```

### Relation Dimensions (EAV on relations)
```sql
CREATE TABLE relation_dimensions (
    relation_id TEXT REFERENCES relations(id),
    dimension TEXT,               -- from dimension registry
    weight REAL                   -- range depends on dimension
);
```

### 17 Seed Dimensions

| # | Dimension | Range | Semantics | Resilience |
|---|-----------|-------|-----------|------------|
| 1 | `is_a` | 0-1 | Taxonomic classification | 0.9 |
| 2 | `has_part` | 0-1 | Part-whole composition | 0.9 |
| 3 | `located_at` | 0-1 | Spatial location | 0.9 |
| 4 | `temporal` | -1 to 1 | Before/simultaneous/after | 0.9 |
| 5 | `causal` | 0-1 | Cause-effect strength | 0.9 |
| 6 | `owns` | 0-1 | Ownership/possession | 0.7 |
| 7 | `prefers` | -1 to 1 | Dislike to strong like | 0.7 |
| 8 | `knows` | 0-1 | Social connection strength | 0.7 |
| 9 | `works_on` | 0-1 | Active involvement | 0.7 |
| 10 | `expertise` | 0-1 | Skill/knowledge level | 0.7 |
| 11 | `emotional` | -1 to 1 | Negative to positive valence | 0.7 |
| 12 | `similarity` | 0-1 | Conceptual similarity | 0.5 |
| 13 | `frequency` | 0-1 | How often relation is active | 0.5 |
| 14 | `trust` | 0-1 | Source reliability | 0.7 |
| 15 | `contradicts` | 0-1 | Contradiction degree | 0.9 |
| 16 | `supersedes` | 0-1 | Newer replacing older | 0.7 |
| 17 | `self_relevance` | 0-1 | Relevance to I-Model | 0.9 |

Resilience = resistance to LLM modification. Learned dimensions start at 0.3 and increase with use. Unused 90d -> auto-deprecated.

### Dimension Registry
```sql
CREATE TABLE dimensions (
    name TEXT PRIMARY KEY,
    description TEXT,
    range_min REAL,
    range_max REAL,
    resilience REAL,             -- 0.3-0.9
    origin TEXT,                 -- "seed", "learned", "user"
    created_at DATETIME
);
```

### Conversation History
```sql
CREATE TABLE conversation_turns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    timestamp DATETIME,
    speaker_id TEXT,              -- diarized
    text TEXT,
    classification TEXT,          -- directed/ambient/ambiguous
    response TEXT,
    language TEXT,
    confidence REAL               -- STT confidence
);
```

### Medium-Term Records
```sql
CREATE TABLE medium_term (
    id TEXT PRIMARY KEY,
    type TEXT,                    -- conversation_summary, recent_fact, observation_pattern
    content TEXT,
    session_id TEXT,
    created_at DATETIME,
    expires_at DATETIME
);
```

## I-Model (Self-Model as Subgraph)

Not a separate data structure. Defined by BFS traversal from `SELF` anchor entity, following relations where `self_relevance >= threshold`.

```
function assemble_i_model(threshold):
    visited = set()
    queue = [SELF_ENTITY]
    subgraph = empty
    while queue:
        entity = queue.pop()
        if entity in visited: continue
        visited.add(entity)
        subgraph.add(entity)
        for relation in entity.outgoing_relations:
            if relation.self_relevance >= threshold:
                subgraph.add(relation)
                queue.append(relation.target)
    return subgraph
```

Threshold is dynamic -- rises under tight token budgets, drops under generous ones.

## Inconsistency Tolerance

Contradictions coexist as entities with `contradicts` relation. Resolution via meta-knowledge entities in the graph:

| Strategy | When Applied |
|----------|-------------|
| `prefer_recent` | Temporal supersession |
| `prefer_authority` | Source provenance (user > inferred) |
| `ask_user` | Similar confidence, high stakes |
| `coexist` | Multi-valued truths (not real contradictions) |

Meta-knowledge is itself learnable and part of the I-Model.

## Context Assembly Pipeline

Per-turn assembly of World-Model from Meta-Model:
1. **Vector retrieval** -- embed query, find top-K similar entities
2. **Graph expansion** -- 1-2 hops from retrieved entities
3. **I-Model merge** -- assemble self-subgraph, deduplicate
4. **Budget allocation** -- trim to token budget with priority ordering:
   - System prompt + persona (highest)
   - I-Model core (identity, capabilities)
   - Conversation buffer
   - Retrieved entities + graph context
   - Medium-term summaries
   - Peripheral I-Model (lowest)

Load factor tunes aggressiveness: <50% generous, 50-80% normal, >80% tight.

## VRAM Tier Reference

| Component | 12 GB | 16 GB | 24 GB |
|-----------|-------|-------|-------|
| LLM | Qwen 3 8B Q4_K_M (~5 GB) | Qwen 3 14B Q4_K_M (~8 GB) | Qwen 3 30B-A3B MoE (~6 GB) |
| STT | faster-whisper Medium (~1.5 GB) | faster-whisper Large V3 (~4.5 GB) | Large V3 (~4.5 GB) |
| TTS | Kokoro-82M (~0.5 GB) | Kokoro-82M (~0.5 GB) | Qwen3-TTS 1.7B (~6 GB) |
| VAD | Silero VAD (CPU) | Silero VAD (CPU) | Silero VAD (CPU) |

## Relevance to Agent-Fleet

Agent-fleet already implements a primitive 3-tier memory via flat files. When the agent-fleet UI becomes an AI OS:
- This schema is the upgrade path for structured memory
- The I-Model pattern maps to persona + user-profile
- Context assembly maps to the CLAUDE.md loading protocol
- Inconsistency tolerance addresses the current flat-file limitation of no contradiction handling
- The 17 seed dimensions provide a richer relationship model than flat contact records
