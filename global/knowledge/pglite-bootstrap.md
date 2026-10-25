---
name: PGlite Bootstrap & Testing Patterns
description: Idempotent bootstrap for PGlite/IndexedDB and in-vitest harness patterns
type: knowledge
---
<!-- updates: none -->
<!-- consumed-by: none -->

# PGlite Bootstrap & Testing Patterns

## Bootstrap Idempotency (IndexedDB Persistence)

**Problem:** PGlite with IndexedDB persistence survives page reloads, but bootstrap SQL (CREATE TYPE, CREATE TABLE) runs unconditionally on every load. Second load fails with `type "priority" already exists` or equivalent.

**Root cause:** Bootstrap assumes a fresh database every time. IndexedDB makes the database durable across sessions, so DDL statements that aren't idempotent crash on reload.

**Fix:** Probe before creating. Use `to_regclass()` (returns NULL if not found) before CREATE TYPE/TABLE:

```sql
-- For types: check pg_type catalog
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'priority') THEN
    CREATE TYPE priority AS ENUM ('low', 'medium', 'high', 'critical');
  END IF;
END $$;

-- For tables: use IF NOT EXISTS (standard SQL)
CREATE TABLE IF NOT EXISTS items (...);

-- For indexes: use IF NOT EXISTS
CREATE INDEX IF NOT EXISTS idx_items_priority ON items(priority);
```

**Applies to:** Any PGlite project using IndexedDB (or OPFS) persistence with Drizzle or raw SQL bootstrap. Also relevant for any embedded database that persists client-side (SQLite/WASM with OPFS, etc.).

**Reference impl:** record the decision in the project's `<project>/docs/decisions.md` (first measured in a fleet PGlite project, 2026)

---

## PGlite-in-Vitest Harness

**Pattern:** Spin up an in-memory PGlite instance per test (no IndexedDB, no persistence). Each test gets a clean Postgres with full SQL support, zero external dependencies.

```typescript
import { PGlite } from '@electric-sql/pglite';

let db: PGlite;

beforeEach(async () => {
  db = new PGlite(); // in-memory, no dataDir = ephemeral
  await db.exec(bootstrapSQL);
});

afterEach(async () => {
  await db.close();
});
```

**Benefits:**
- Real Postgres SQL dialect (not SQLite approximation)
- Full isolation between tests
- No test database server to manage
- Fast startup (~50ms per instance)

**Applies to:** Any project using PGlite where you need unit/integration tests against real Postgres behavior.

---

## Schema-Version Reset-on-Upgrade Migration

**Pattern:** When the schema changes during development, detect version mismatch and drop/recreate rather than running incremental migrations. Suitable for client-side apps where data loss on upgrade is acceptable (the server is the source of truth).

Store a schema version in a metadata table. On bootstrap, compare stored version to expected version. If mismatch, drop all tables and re-bootstrap.

**When to use:** Early development, client-side caches, browser-local data that can be re-fetched. NOT for production server databases.

---

## jsdom + Recharts ResponsiveContainer Mock

**Pattern:** Recharts `ResponsiveContainer` relies on `ResizeObserver` and real DOM measurements, which jsdom doesn't provide. Tests crash or render nothing.

**Fix:** Mock `ResponsiveContainer` to render children with fixed dimensions:

```typescript
vi.mock('recharts', async () => {
  const actual = await vi.importActual('recharts');
  return {
    ...actual,
    ResponsiveContainer: ({ children }: { children: React.ReactElement }) =>
      React.cloneElement(children, { width: 500, height: 300 }),
  };
});
```

**Applies to:** Any Vitest/Jest + jsdom project using Recharts (or similar chart libraries that depend on DOM measurements).

**Reference impls:** the test suite of a fleet PGlite + Recharts project (`<project>/` tests)
