# Fleet-to-GitHub Issue Protocol

File issues on the public `agent-fleet` repo for improvements that benefit all deployments.

## When to File

**File** when:
- Template-worthy improvements discovered during `lrn` audits
- Bugs in scripts/hooks that affect any deployment (not just personal config)
- Features that would help any agent-fleet user
- Documentation gaps in the public template

**Do NOT file** when:
- Issue is personal deployment-specific (use private backlog instead)
- Issue involves private repos, credentials, or personal data
- Issue is already tracked in the private backlog with no public benefit

## How to File

### 1. Write the issue body to a temp file
Write the description to a file (not inline). This enables automated scrubbing.

### 2. Privacy scrub (MANDATORY — never skip)
```bash
bash setup/scripts/fleet-issue.sh --scrub <body_file>
```
- Exit 0 = clean. Proceed.
- Exit 1 = violations found. Rewrite the body, re-scrub. Never file without passing.

**Safe substitutions:**
| Private | Public replacement |
|---------|--------------------|
| Machine-specific names (hostnames, platforms) | "a fleet machine" |
| Private config repo path | "private config repo" |
| Hostnames / IPs | "a host" |
| /home/<user>/ | ~/ |
| Personal names | omit entirely |
| Corporate / employer-specific content | "employer project" |

### 3. Dedup check
```bash
bash setup/scripts/fleet-issue.sh --dedup "<title>" [index_file]
```
- Exit 0 = no duplicate. Proceed.
- Exit 2 = duplicate found. Skip or comment on existing issue instead.

Also check GitHub:
```
mcp__github__search_issues with query: "repo:<owner>/agent-fleet <keywords>"
```

### 4. Format the issue
```bash
bash setup/scripts/fleet-issue.sh --format "<title>" "<category>" "<severity>" <body_file>
```
Categories: `bug`, `feature`, `rule-change`, `improvement`, `docs`
Severity: `critical`, `high`, `medium`, `low`

### 5. Opus review gate
Before filing, spin up an Opus subagent to review:
- Is this genuinely template-worthy?
- Does the body pass privacy review (human judgment, not just regex)?
- Is the title clear and actionable?

### 6. File via GitHub MCP
- **Public agent-fleet:** `mcp__github__create_issue` on `<owner>/agent-fleet`
- **Corporate:** Use the appropriate org MCP server and repo
- Labels: `fleet-reported`, plus category label (`bug`, `feature`, etc.), plus `needs-triage`

### 7. Record locally
```bash
bash setup/scripts/fleet-issue.sh --record "<title>" <issue_number> [index_file]
```

## Rate Limit

**Maximum 3 issues per session.** Quality over quantity. If more than 3 issues emerge, batch them or defer low-priority ones to the next session's backlog.

## Issue Body Template

```markdown
## Description
[Clear description — no personal data]

## Context
- **Category:** [bug | feature | rule-change | improvement | docs]
- **Discovered via:** [lrn-audit | normal-work | user-report | hook-detection]
- **Severity:** [critical | high | medium | low]

## Reproduction / Rationale
[For bugs: steps. For features: why this helps all deployments.]

## Proposed Solution
[If known.]

---
<details>
<summary>Fleet Metadata</summary>

- Machine: a fleet machine
- Session: [date only]
- Source: relates to internal tracking
- Config version: [git short hash]
</details>
```

## Labels (pre-create on agent-fleet repo)

| Label | Purpose |
|-------|---------|
| `fleet-reported` | All fleet-filed issues (required) |
| `bug` | Bug reports |
| `feature` | Feature requests |
| `rule-change` | CLAUDE.md or protocol changes |
| `improvement` | Non-bug improvements |
| `docs` | Documentation |
| `needs-triage` | Auto-applied, removed after review |

## Local Dedup Index

Location: `~/.claude/.fleet-issues.jsonl` (gitignored, per-machine)

Format (one JSON object per line):
```json
{"title":"Issue title","number":42,"date":"2026-03-12"}
```

The index is checked before filing to avoid duplicates from the same machine. Cross-machine dedup uses GitHub search.
