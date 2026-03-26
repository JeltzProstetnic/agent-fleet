# Gmail Management

## Overview

Knowledge file for managing Gmail via Google Workspace MCP tools (`mcp__workspace__*`).
Cross-project capability — Gmail may serve multiple projects (outreach, visibility, work routing, personal/admin tasks).

**Accounts covered:**
| Address | Role | Notes |
|---------|------|-------|
| `your-email@gmail.com` | Primary | Google Workspace MCP target. All MCP operations use this account. |

Add additional aliases (professional, forwarding addresses) to this table as needed.

**Persona mail = intake queue.** If using a persona-specific email address filtered to a label: (1) read each message, (2) ingest content — create inbox tasks, backlog items, knowledge updates, or act immediately as appropriate, (3) **trash the email IMMEDIATELY** — not deferred, not batched, not "after processing all." Each message: read → ingest → trash, then next message. Processing is complete only when the email is trashed. This prevents cross-session dedup failures where a later session re-processes untrashed mail.

**Load trigger:** Gmail triage, inbox management, spam cleanup, label operations.

## Draft Lifecycle — MANDATORY

**Before creating a draft, trash any existing draft for the same recipient+subject.** Gmail's draft UX makes duplicate drafts indistinguishable — the user can't tell which is current. This is the agent's responsibility, not the user's.

1. Before `draft_gmail_message`: search `in:drafts to:<recipient>` (or `subject:<topic>`)
2. If a matching draft exists: trash it with `modify_gmail_message_labels` (add TRASH)
3. Then create the new draft

**Before recreating a "missing" draft:** Check Sent folder first — the user may have already sent it. Missing draft ≠ lost draft.

## Triage Protocol

Inbox zero approach. Systematic, repeatable, 10-at-a-time batch processing.

### De-duplication Check — MANDATORY BEFORE TRIAGE

Before classifying any email, cross-reference the sender+topic against:

1. **Cross-project inbox completed items** — `inbox.md` entries marked `[x]`
2. **Recent git commit messages** — visible at session startup (git log in systemMessage)
3. **Session history** — `session-history.md` if available

If a sender+topic matches a completed item, **flag the match** and assess: is this the same correspondence already processed, or a new message requiring fresh action? Present the match context to the user rather than silently treating the email as new. The goal is informed triage — avoid both re-processing handled correspondence AND accidentally ignoring genuinely new follow-ups.

### Two-Inbox Strategy

User's inbox = personal life (flights, orders, known people). Persona label = project-related automated mail (CI, cloud notifications, service alerts). Progressive filtering: in doubt, leave in user's inbox. Add filters as patterns emerge during triage.

**Persona triage step:** At the start of each triage session, also check persona-labeled unread mail for automated messages that may need action (e.g., CI failures indicating broken tests).

### Workflow

1. **Fetch batch:** `search_gmail_messages` with query `in:inbox` (or `is:unread`), limit 10
2. **Read subjects/senders:** Scan the batch for obvious actions before reading bodies
3. **Decide per message:** Apply the decision framework below
4. **Act:** Execute the decision (archive, label, reply-draft, delete)
5. **Report:** Summarize batch to user — what was done, what needs human input
6. **Repeat:** Next batch of 10 until inbox is clear or user stops

### Decision Framework

For each message, classify into exactly one action:

| Action | When | MCP operation |
|--------|------|---------------|
| **Respond** | Requires user's reply. Draft it, present for approval. | `draft_gmail_message` |
| **Archive** | Informational, read, no action needed. | `modify_gmail_message_labels` (remove INBOX) |
| **Defer** | Needs action but not now. Label + archive. | `modify_gmail_message_labels` (add label, remove INBOX) |
| **Unsubscribe** | Recurring unwanted mail. Unsubscribe link + archive. | Note sender in Sender Preferences, archive |
| **Delete** | Spam, expired promos, zero value. | `modify_gmail_message_labels` (add TRASH) |

**Escalation:** If unsure about a message, present it to the user with a recommendation. Never delete anything ambiguous silently.

### Batch Labeling

Use `batch_modify_gmail_message_labels` when applying the same action to multiple messages (e.g., archiving 5 newsletters at once). More efficient than individual calls.

## Label Taxonomy

Populate with actual Gmail labels via `list_gmail_labels`.

### Suggested Categories

| Category | Label pattern | Purpose |
|----------|--------------|---------|
| **Persona routing** | `<persona-name>` | Persona-specific mail (forwarded/filtered) |
| **Project routing** | `<project-name>` | Route to project context |
| **Action status** | `action-needed`, `waiting-reply`, `deferred` | Track items requiring follow-up |
| **Importance** | (use Gmail's built-in importance markers) | Priority signal |
| **Sender type** | `researcher`, `conference`, `newsletter` | Classify by origin |

### Discovered Labels

_Populate this table during first triage session using `list_gmail_labels`._

| Label | ID | Notes |
|-------|-----|-------|
| | | |

## Sender Preferences

Known senders and their default disposition. Updated as triage decisions accumulate.

| Sender / Domain | Disposition | Notes |
|----------------|-------------|-------|
| `notifications@github.com` (CI) | Persona triage | Filter: subject "Run failed/cancelled/errored" → skip inbox, label persona. CI failures may need action. |

_Populated during triage sessions._

## Spam & Cleanup Strategy

### Spam Patterns to Watch

- Crypto/investment scam newsletters
- Fake invoice / payment confirmation phishing
- "Your account has been compromised" social engineering
- Marketing from services with no prior relationship
- Non-English bulk mail (unless expected — e.g., business correspondence in your language is legitimate)

### False Positive Recovery

Gmail's spam filter occasionally catches legitimate mail, especially:
- First-time senders from small domains (e.g., researcher outreach replies)
- Auto-forwarded mail from custom domains (forwarding chains lower sender reputation)
- Conference system auto-replies (noreply@ addresses)

**Recovery protocol:**
1. Periodically check spam folder: `search_gmail_messages` with query `in:spam newer_than:7d`
2. Review subjects and senders for known contacts or expected domains
3. If false positive: move to inbox, add sender to Sender Preferences as "keep"
4. If pattern repeats: create a Gmail filter via `manage_gmail_filter` to never-spam that sender/domain

### Trash Cleanup

- Gmail auto-deletes trash after 30 days — no manual cleanup needed for most cases
- For bulk cleanup (e.g., 500+ promo emails): use `search_gmail_messages` with targeted query, then `batch_modify_gmail_message_labels` to trash in batches

## Archive Strategy

### When to Archive vs Delete

| Archive (keep searchable) | Delete (trash) |
|--------------------------|----------------|
| Any professional correspondence | Expired promotions / deals |
| Conference notifications | Duplicate notifications |
| Receipts and order confirmations | Spam that passed filters |
| Newsletters user chose to keep | Password reset emails (after use) |
| Anything with potential future reference | Automated test/deploy notifications (old) |

### Search-Based Retrieval

Archived mail is fully searchable. Preferred search patterns:

| Need | Query |
|------|-------|
| From a specific person | `from:name@domain.com` |
| Project-related | `label:<project>` or `subject:(<keywords>)` |
| Recent important | `is:important newer_than:30d` |
| Attachments from someone | `from:name has:attachment` |
| Sent replies | `in:sent to:name@domain.com` |

### Gmail Check Protocol — MANDATORY

**Fleet-wide tracking.** Before any Gmail triage, check the marker below. After triage, update it. This prevents cross-session re-processing.

<!-- Last triage: YYYY-MM-DD HH:MM machine project -->

**High-water mark approach.** After each Gmail check, update BOTH (1) the fleet-wide marker above AND (2) session-context.md (e.g., `- **Last Gmail check**: 2026-03-17T16:30`). On next check, use `after:YYYY/MM/DD` based on the fleet marker date. This handles weekends, vacations, any gap length, AND cross-project dedup.

**Search:** `after:YYYY/MM/DD` (date of last check), NO `is:unread` filter, `page_size: 10`, `format: metadata` first. The user frequently reads email in Gmail before asking the agent to check — `is:unread` is unreliable. Scan subjects/senders from metadata, fetch full content only for relevant messages.

**When the user says they expect a specific email:** Search by sender (`from:`) or subject (`subject:`). User-provided information overrides search results — if they say "there's an email" and the search returns nothing, broaden the search.

## Decision Log

Triage decisions and policy changes are logged here for pattern recognition.

| Date | Decision | Rationale |
|------|----------|-----------|
| | | |
