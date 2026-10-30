---
name: Test Isolation Guards
description: Prevent tests from silently hitting live services via env var defaults
type: knowledge
---
<!-- updates: none -->
<!-- consumed-by: none -->

# Test Isolation Guards

## The Bug

Tests silently hit a live production service because client code defaults to a hardcoded prod URL when an env var is unset:

```python
# In client code -- the anti-pattern
url = os.getenv("SERVICE_URL", DEFAULT_PROD_URL)  # DEFAULT_PROD_URL = "http://192.0.2.10:8080"
```

When the test environment doesn't set `SERVICE_URL`, every test that exercises the client sends real HTTP requests to the production server. This causes:

- Flaky tests (pass on LAN, fail on CI or remote machines)
- Silent data mutation in production
- False green (tests "pass" because prod happens to return valid data)
- Impossible-to-debug failures when the service is down

## The Fix: conftest.py Autouse Guard

Two-layer defense in `conftest.py`:

```python
import pytest

@pytest.fixture(autouse=True)
def _block_live_services(monkeypatch):
    """Prevent any test from reaching live services."""
    # Layer 1: Force env var empty so client code can't silently default to prod
    monkeypatch.setenv("SERVICE_URL", "")

    # Layer 2: Monkeypatch the HTTP chokepoint to raise on any real request
    import httpx  # or requests, urllib3, etc.
    def _blocked(*args, **kwargs):
        raise RuntimeError(
            "Test attempted live HTTP request. "
            "Use a mock or set SERVICE_URL to a test instance."
        )
    monkeypatch.setattr(httpx, "Client", _blocked)
    monkeypatch.setattr(httpx, "AsyncClient", _blocked)
```

Tests that genuinely need HTTP must explicitly override with a mock or test-instance URL.

## The Anti-Pattern

```python
# NEVER do this -- env var default pointing to production
DEFAULT_URL = "http://192.0.2.10:8080"
url = os.getenv("SERVICE_URL", DEFAULT_URL)

# INSTEAD -- fail fast when env var is missing
url = os.environ["SERVICE_URL"]  # KeyError in tests = good, forces explicit config

# OR -- default to empty/localhost, never prod
url = os.getenv("SERVICE_URL", "")
if not url:
    raise ValueError("SERVICE_URL not configured")
```

**Rule:** Environment variable defaults must NEVER point to production. Acceptable defaults: empty string, localhost, `http://test.invalid`, or no default at all (require explicit config).

## Broader Application

This pattern applies beyond Python/pytest:

- **Node.js/Vitest:** Use `beforeAll` to set `process.env.SERVICE_URL = ""` and mock `fetch`/`axios`
- **Go:** Use `TestMain` to set env vars and provide a test HTTP server
- **Any language:** The principle is the same -- tests must not be able to reach production by default. The guard must be autouse/global, not per-test (because the bug is tests that DON'T know they need a mock)

## Guard Placement: Define Once, in the ROOT conftest.py

**A conftest guard only protects its own directory tree -- a sibling test tree inherits nothing.** Measured in a fleet project, 2026-09: `tests/conftest.py` carried a thorough autouse set (live-DB paths, a subprocess blocklist covering ssh/flatpak/chrome, server catalog+ops HTTP, plan-push, ingest tier roots) and looked complete. But pytest applies a conftest only to tests at or below its own directory, and `pyproject.toml` had `testpaths = ["tests"]`, so a second tree at `server2/tests/` (150 tests, its own conftest holding nothing but a `sys.path` insert) had **zero** protection -- and was simply never collected, which is why nobody noticed for months.

**The naive fix makes it worse:** adding `server2/tests` to `testpaths` would have run 150 previously-unrun tests against live production machines with no guard at all, at a time when the user had explicitly ordered those machines kept quiet.

**Rule:** define the guards exactly once in the **root** `conftest.py`, not per-tree. pytest applies the root conftest to every tree under rootdir, a closer conftest overrides by name, and a single definition is what stops two copies drifting. Wrap each guard's import in `try/except ImportError` so a tree that cannot import the other tree's modules degrades to a no-op instead of erroring.

**Guards are class-specific -- enumerate every DB class and every deployed path root.** The same move found the live-path set wrapped `server.database.Database` but not `server2.db.Database`, so the second service's own DB class was unguarded even in the tree that had guards. List every DB class and every deployed root (`/opt/<service>/` in this case), not just the ones the first author happened to use.

Measured result: the 150 tests then passed under the guards with nothing tripping them -- they were already hermetic in practice, just unprotected, which is exactly how this survives review.

## Checklist for New Projects

1. Identify all env vars that configure service URLs
2. Verify none default to production addresses
3. Add autouse conftest guard that forces them empty
4. Monkeypatch the HTTP layer as a second safety net
5. Document which test fixtures provide mock/test-instance access
6. `find . -name conftest.py` -- confirm every test tree is covered by a conftest that CARRIES the guards, not merely by one that exists (define them once in the root conftest; see above)
7. Wrap each guard's import in `try/except ImportError` so a tree that cannot import the guarded modules degrades to a no-op instead of erroring
8. Enumerate every DB class and every deployed path root in the live-path set, not just the ones the first author used

## Source

Measured in a fleet project, 2026-05; guard placement and DB-class enumeration: same project, 2026-09

---

# Green That Verifies Nothing

The env-var bug above is one member of a family: a suite or gate that **reports success without
having exercised the thing**. Two more members, both measured.

## A test that SKIPS in the environment where it was written verifies NOTHING

A subagent wrote a spiking-neuron (LIF) module with `torch` absent, so its behavioral tests were
guarded by `pytest.importorskip("torch")`. They **skipped**, the suite came back green, and the
module read as done. When torch was later installed on the box that actually has the GPU, the module
was **silently broken — it fired zero spikes**.

**Rule:** any module behind an optional or hardware-gated extra must be **run on the target
hardware** before it is trusted or marked done. Treat "green with skips" as **unverified for every
skipped path**, and say so in the handover rather than reporting a pass. The authoring environment
deciding which tests run is exactly the condition under which a green suite carries no information.

Source: measured in a fleet project, 2026-07.

## Red-team the DV, the reward and the observability BEFORE spending the compute

A learning-dynamics red-team ran a **torch-free probe** on a planned
ablation and found the reward geometry would produce a **FALSE NULL** — a cue-blind, closure-free
strategy (one-side homing, exploiting a position that was already in the observation) was survivable
and high-scoring, so ablation-ON would have scored ≈ ablation-OFF. That is indistinguishable from a
legitimate decisive negative, and the expensive run would have "produced a result".

**The gate that missed it was "the mechanism is decodable" — decodable ≠ used.**

**Rule:** before any expensive ablation or 2×2 experiment, adversarially stress the dependent
variable, the reward and the observability with a small cheap probe, asking *what can the agent
exploit that bypasses the mechanism under test?* — and require a **behavioral** gate (the mechanism
must be demonstrably USED) rather than a presence/decodability gate. Same reasoning as the skip case:
ask what the green outcome would look like if the mechanism were absent, and if the answer is
"identical", the gate is measuring nothing.

Source: measured in a fleet project, 2026-07.
