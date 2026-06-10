# Choosing Your Claude Model: Opus 4.6 / 4.7 / 4.8 — and Fable 5

**Audience:** Anyone who installed `agent-fleet` and wants to understand which Claude model they got, why, and how to switch.

---

## The short version

When you run `setup.sh`, the installer pulls the latest published Claude Code from npm and uses whichever model that build defaults to. As of June 2026, that means **you get Opus 4.8** (the bundled default since CC 2.1.153, released 2026-05-28). On CC 2.1.170+ you can additionally select **Fable 5**, Anthropic's preview flagship. If you want an older Opus instead — for example, because you need Opus 4.6's Fast Mode — set `CLAUDE_CODE_VERSION` at install time:

```bash
CLAUDE_CODE_VERSION=2.1.110 bash setup.sh   # gives Opus 4.6 + Fast Mode
CLAUDE_CODE_VERSION=2.1.152 bash setup.sh   # gives Opus 4.7 (last 4.7-default release)
bash setup.sh                                # default — whatever's current on npm (Opus 4.8 today)
```

You can also switch post-install with one command (see [Switching versions](#switching-versions)).

There is no "wrong" choice. The two models target different priorities, and the fleet works correctly with either.

---

## What you actually have right now

```bash
mclaude --version
```

Map the version number to the model:

| You see | You're running |
|---------|----------------|
| `2.1.110` or earlier | Opus 4.6 (default at install time was 4.6) |
| `2.1.111` – `2.1.152` | Opus 4.7 (default flipped on 2026-04-23) |
| `2.1.153` or later   | Opus 4.8 (default flipped on 2026-05-28) |
| `2.1.170` or later   | Opus 4.8 by default, **Fable 5 selectable** (alias `fable`, id `claude-fable-5`) |

This mapping holds for fresh installs. If you've manually pinned a version, the pin wins regardless of what npm currently publishes.

---

## How the two models differ

| | Opus 4.6 | Opus 4.7 |
|---|---|---|
| Context window | 1M tokens | 1M tokens |
| Knowledge cutoff | January 2025 | January 2026 |
| Default effort level | `high` (since CC 2.1.111) | `xhigh` (since CC 2.1.117) |
| Fast Mode (`/fast`) | **Yes** — 2.5× output speed at 6× cost, requires CC 2.1.36+ | No — Anthropic did not port Fast Mode forward |
| `auto` effort mode | No | Yes (Max subscribers only) |
| Released | Late 2025 | March 2026, GA April 16, 2026 |

**When Opus 4.6 makes sense:** You've built a workflow around `/fast` for short, latency-sensitive iterations. You don't need 2025-2026 knowledge. You want behavior continuity with what you've been using since the fleet's early months.

**When Opus 4.7 makes sense:** You want the newer training data, the higher default effort, and Anthropic's current focus of investment. You don't use `/fast` (most users don't — it's a 6x markup).

---

## Opus 4.8 and Fable 5

**Opus 4.8** (released 2026-05-28) is the current Opus generation and the bundled default on CC 2.1.153+. Same base pricing as 4.6/4.7, 1M context window, and it brings Fast Mode back. For most users, "do nothing" now means Opus 4.8.

**Fable 5** is Anthropic's preview flagship (announced 2026-06-09) — a tier above Opus, SOTA on most benchmarks, priced at $10/M input and $50/M output. It is **selectable, never the default**: it requires CC 2.1.170+ and an account where the model is enabled. Use the alias `fable` or the full id `claude-fable-5`. In high-risk domains it auto-falls back to Opus 4.8.

Recommended ways to use Fable 5 without losing the Opus 4.8 default:

1. **Subagent (best):** define an agent with `model: claude-fable-5` and invoke it on demand — no manual toggling.
2. **Dedicated session:** launch a separate session/tab with `--model fable`.
3. **Session-only switch:** open the `/model` picker and press `s` (session-only). Plain `/model fable` + Enter **persists** the new default — avoid unless that's intended.

---

## Switching versions

The mechanism is the same in both directions: re-install Claude Code at a specific version, then restart your session.

### Downgrade to Opus 4.6 (any version 2.1.76 – 2.1.110)

```bash
cc-mirror update mclaude --claude-version 2.1.110 --no-tweak
```

Recommended: pin to `2.1.110` specifically (the last 4.6-default release). Older versions work but miss bug fixes — for example, the 1M context handling on Opus 4.6 itself was only stable from CC 2.1.76 onward.

### Upgrade to latest (Opus 4.8, Fable 5 selectable)

```bash
cc-mirror update mclaude --claude-version latest --no-tweak
```

Or pin to a specific era:

```bash
cc-mirror update mclaude --claude-version 2.1.152 --no-tweak   # last Opus 4.7-default release
cc-mirror update mclaude --claude-version 2.1.170 --no-tweak   # Opus 4.8 default + Fable 5 selectable
```

### After switching

1. Exit any running `mclaude` session (`/exit`).
2. Confirm the change: `mclaude --version`
3. Start a new session. The model in use will reflect whichever Opus that CC version bundles.

---

## Install-time version pinning

`setup.sh` honours the `CLAUDE_CODE_VERSION` environment variable. Set it before running setup to pin a specific Claude Code (and therefore Opus) version on the very first install — no post-install update step needed:

```bash
CLAUDE_CODE_VERSION=2.1.110 bash setup.sh   # Opus 4.6 + Fast Mode
CLAUDE_CODE_VERSION=2.1.152 bash setup.sh   # Opus 4.7, pinned (last 4.7-default release)
CLAUDE_CODE_VERSION=2.1.170 bash setup.sh   # Opus 4.8 default, Fable 5 selectable
CLAUDE_CODE_VERSION=latest bash setup.sh    # explicit "latest" (default if unset)
bash setup.sh                                # same as latest
```

The variable is per-machine (each `setup.sh` run is independent). For team-wide pinning across multiple machines, the simplest pattern today is to commit a tiny wrapper script that invokes `CLAUDE_CODE_VERSION=<chosen> bash setup.sh`. A first-class `.claude-code-version` pin file in the repo root is being considered but is not yet implemented.

---

## Frequently asked

**Can I run both 4.6 and 4.7 side by side?** Yes — `cc-mirror` supports multiple named variants. `cc-mirror quick --provider mirror --name mclaude46 --claude-version 2.1.110 --no-tweak` creates a second launcher (`mclaude46`) parallel to your main `mclaude`. Each variant has its own settings.json and config dir.

**Will auto-update flip me from 4.6 to 4.7 behind my back?** No. The fleet sets `DISABLE_AUTOUPDATER=1` in `settings.json`, so Claude Code won't update itself between sessions. You only get a new bundled model when you explicitly run `cc-mirror update`.

**What if I just want to keep using whatever I have?** Do nothing. The fleet works correctly with both versions. The only difference you'll notice in day-to-day work is whether `/fast` is available.

**Does the agent know which model it's running?** Partially. The CC version is reported by `mclaude --version`, and the `fleet-capabilities` reference maps versions to models. The agent doesn't have an automatic injection of model identity in every session yet — that's planned but not implemented.

---

## Sources

- Anthropic GA announcement: Opus 4.7 generally available 2026-04-16
- Default model flipped to Opus 4.7 for Enterprise pay-as-you-go and Anthropic API users on 2026-04-23
- Fast Mode is currently Opus 4.6 only — Anthropic confirmed via API docs
- CC 2.1.111 release notes: introduced Opus 4.7 + xhigh effort, raised default effort for 4.6/Sonnet 4.6 to `high`
- CC 2.1.113 release notes: fixed Opus 4.7 sessions computing against 200K context instead of native 1M
- Opus 4.8 released 2026-05-28; became the CC bundled default with CC 2.1.153
- Fable 5 announced 2026-06-09 (anthropic.com/news/claude-fable-5-mythos-5); selectable in Claude Code 2.1.170+
