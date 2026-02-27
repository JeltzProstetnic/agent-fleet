# Decisions & Requirements — Agent Fleet

## Architecture & Design

### Shebang convention: `#!/usr/bin/env bash`
**Date:** 2026-02-27
**Decision:** All shell scripts use `#!/usr/bin/env bash` for portability (macOS, NixOS, BSDs where bash is not at `/bin/bash`).

### JSON output in hooks uses python3
**Date:** 2026-02-27
**Decision:** Hooks that emit JSON (e.g., config-check.sh) use `python3 -c "import json; ..."` instead of manual string concatenation, preventing escaping bugs with special characters.

## User Requirements

## Conventions

## Rejected / Superseded
