<!-- Fill this in during shutdown if the next session should continue specific work.
     Required fields: task: true|false, file: <path>, description: <text>
     The file: MUST point to a dedicated file (e.g., docs/pending-*.md), NEVER to session-context.md.
     rotate-session.sh extracts this section to next-session-task.md automatically. -->
task: true
file: docs/pending-e2e-test.md
description: Run E2E onboarding test in Ubuntu-24.04 WSL instance with API key (option 1). Also: scrollback fix propagation, install-skill-collections global enabledPlugins bug.
