---
name: GLib idle_add + return-True Tight Loop
description: Reusing a recurring (return-True) callback in a one-shot idle_add creates a busy-loop
type: knowledge
---
<!-- updates: none -->
<!-- consumed-by: none -->

# GLib idle_add + return-True Tight Loop

## The Pitfall

GLib idle/timeout sources are removed only when their callback returns `False` / `GLib.SOURCE_REMOVE`. A callback written for recurring use returns `True` / `GLib.SOURCE_CONTINUE` to keep the source alive.

When you reuse such a callback verbatim inside `GLib.idle_add()` for a one-shot call, the source is never removed -- `idle_add` keeps re-invoking it as fast as the main loop spins, silently turning a single dispatch into a busy-loop.

In one real case this produced a **257 Hz busy-loop** that pegged CPU on the affected machines. It was latent for ~2 months before being found.

## The Fix

For a one-shot call that reuses a multi-fire callback, force a `False` return so the source is removed after one run:

```python
GLib.idle_add(lambda: (callback(), False)[1])
```

The tuple evaluates `callback()` for its side effect, then returns `False` (index `[1]`), so GLib removes the idle source after a single dispatch.

## Root Cause

GLib idle/timeout sources persist until the callback returns `False` / `GLib.SOURCE_REMOVE`. A recurring callback returns `True` / `GLib.SOURCE_CONTINUE` -- reusing it as-is in a one-shot `idle_add` means the source never gets removed, and the busy-loop is silent (no error, no crash, just pegged CPU).

## Source

Observed in a GTK desktop application, 2026.
