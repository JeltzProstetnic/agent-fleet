# Project Type Taxonomy

Canonical project types for the fleet. Used by `registry.md`, `setup-project-roster.sh`,
and `project-setup.md` for type-aware setup, roster selection, and sibling consultation.

## Canonical Types

| Type | Definition | Default Bundles | Example Projects |
|------|-----------|-----------------|-----------------|
| `code` | Software development — any language, framework, or platform | core-dev, lang, qa-sec | my-app, api-server |
| `writing` | Long-form authoring — books, fiction, creative writing | research | novel, blog |
| `research` | Academic research, publications, data analysis, statistical work | research, data-ai | — |
| `config` | Configuration management, fleet infrastructure, meta-tooling | infra, dev-exp | agent-fleet |
| `infra` | Infrastructure — servers, networking, deployment, home lab | infra, dev-exp | infrastructure |
| `marketing` | Social media, engagement, visibility campaigns | research, biz | social |
| `business` | Process analysis, corporate tooling, decision support | biz, research | — |
| `data` | Data processing, catalogs, ETL, search/indexing | data-ai, research | — |
| `media` | Media management — organization, dedup, sync, catalog | data-ai, core-dev | — |
| `tooling` | Integration tooling — connecting systems, automation | core-dev, infra, biz | — |

## Compound Types

Projects often span multiple types. Use `+` to combine:

- `research + writing` — academic authoring (papers, books with research component). Bundles: research, data-ai
- `research + code` — research with significant implementation. Bundles: research, data-ai, core-dev, lang
- `research + writing + code` — full-stack academic project. Bundles: research, data-ai, core-dev, lang
- `code + infra` — application with infrastructure components. Bundles: core-dev, lang, infra

**Rules:**
- Always use `+` with spaces as separator: `research + writing`, not `research/writing`
- List types in order of primary focus: `research + writing` means primarily research
- Compound bundles = union of both types' defaults (deduplicated)
- Registry Type column MUST use canonical types from this list

## Type → Bundle Mapping

The `TYPE_BUNDLE_MAP` in `setup-project-roster.sh` maps types to VoltAgent plugin bundles.
This taxonomy is the authoritative source — the script should mirror these mappings.

Bundle names are without the `voltagent-` prefix for readability. Full bundle names:
`voltagent-core-dev`, `voltagent-lang`, `voltagent-qa-sec`, `voltagent-research`,
`voltagent-data-ai`, `voltagent-infra`, `voltagent-dev-exp`, `voltagent-biz`,
`voltagent-domains`, `voltagent-meta`.

## Phase-Based Roster Adjustment

A project's type determines its DEFAULT roster, but the active session phase may need
different agents. See `foundation/roster-management.md` Section 4 for phase-based
roster examples.

## Pattern Extraction Protocol

When a project reaches maturity (50+ commits, stable CLAUDE.md, proven workflows):
1. Compare its CLAUDE.md against the type template in `setup/projects/_templates/<type>/`
2. Identify generalizable patterns not yet in the template
3. Extract and add to the template
4. Create an inbox task for the config project if the template was updated

This is a judgment task for the LLM, not a mechanical script.

**Session integration:** The shutdown checklist (Step 5.5 — "Postmortem pattern extraction") ensures
reusable patterns discovered during any session are routed to the config project for template integration.
This closes the feedback loop between project-level learnings and fleet infrastructure.
