# Operational Knowledge — dev-browser Skill

## Startup

**Command** (run from the project root that has the skill installed):
```bash
cd skills/dev-browser && ./server.sh &
```
The `skills/` directory is relative to the current project root.

**Wait for:** `Ready` message in output. Don't waste turns checking process status or polling pages — the message confirms full readiness.

## Chromium Version Drift

**Problem:** dev-browser and Playwright MCP maintain separate Playwright versions. An MCP tool update can remove the Chromium binary dev-browser expects.

**Symptom:** Startup fails with "Chromium not found" or similar error.

**Fix:**
```bash
cd skills/dev-browser && npx playwright install chromium
```

**Note:** This is the only npm install you need. Core dependencies are already installed — don't re-run `npm i` unless you see an actual missing module error.

## Session Persistence

**Cookie storage:** `profiles/browser-data/` — persists across restarts in standalone mode.

**Login requirement:** Standalone mode requires manual login on first use. Subsequent sessions reuse cookies from `browser-data/`.

## Access

The dev-browser skill is triggered via `/dev-browser` skill command. This file provides operational knowledge for troubleshooting and maintenance — not user-facing documentation.
