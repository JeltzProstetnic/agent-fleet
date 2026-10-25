---
name: Anti-Chain / Cooldown State Pattern
description: State mutations must reflect successful side effects, not selection attempts
type: knowledge
---
<!-- updates: none -->
<!-- consumed-by: none -->

# Anti-Chain / Cooldown State Pattern

## The Bug

Anti-chain/cooldown state is set BEFORE the side effect succeeds. Silent failures still trip the cooldown, making the failed option "used up" -- it stays invisible while the system believes it was shown.

**Concrete example:** A content selector sets `_last_type = "poem"` before generating the poem. Generation fails silently (empty result, network error, filter rejection). The anti-chain now suppresses "poem" for the cooldown period. The user never sees a poem, but the system thinks it just showed one.

## The Pattern

**State mutation MUST follow successful emission, not selection.**

```python
# WRONG -- state before side effect
def select_and_emit(self):
    chosen = self.weighted_pick()
    self._last_type = chosen        # <-- state set here
    self._cooldown[chosen] = now()
    result = self.generate(chosen)   # might fail silently
    return result                    # might be None/empty

# RIGHT -- state after confirmed success
def select_and_emit(self):
    chosen = self.weighted_pick()
    result = self.generate(chosen)
    if result:                       # only mutate on success
        self._last_type = chosen
        self._cooldown[chosen] = now()
    return result
```

## Where This Applies

This is not limited to anti-chain selectors. The same bug class appears in:

- **Weighted-random pickers** -- marking an option as "recently used" before confirming it was actually used
- **Retry/backoff timers** -- incrementing retry count before the attempt completes (failed attempts that should allow immediate retry instead trigger exponential backoff)
- **Repeat-suppression** -- "don't show the same thing twice" logic that counts attempts instead of successes
- **Rate limiters** -- decrementing quota before the request is fulfilled
- **Circuit breakers** -- opening the circuit on attempt rather than on confirmed failure

## General Rule

**"We tried" is not "we did."** Any state that gates future behavior (cooldowns, quotas, dedup sets, retry counters) must reflect outcomes, not intentions. If the operation can fail silently, the state mutation must be conditional on success.

## Source

Found in a fleet media project, 2026-05-15.
