# Twitter Engagement Protocol — MANDATORY

**Load this file at session start when the session involves Twitter/X engagement, discourse scanning, or reply drafting.**

---

## 1. Engagement Tracking — Single Source of Truth

Every posted tweet MUST be tracked in `session-context.md` under **Key Engagement Targets** with status:

| Status | Meaning |
|--------|---------|
| POSTED | Reply sent, no response expected or received |
| AWAITING REPLY | Reply sent, waiting for response from target |
| EXCHANGE ACTIVE | Back-and-forth conversation in progress |
| DRAFTED | Draft ready in `tmp/`, not yet posted by user |

### Before recommending ANY engagement target:

1. Read `session-context.md` — check engagement target statuses
2. Read `tmp/day*-engagement-replies.txt` — check what's been posted
3. Cross-reference the target URL against both sources
4. **If already engaged: DO NOT recommend again.** Flag it as "already engaged" and skip.

---

## 2. Discourse Scan Protocol

### Scan agents have NO CONTEXT about prior engagement

Scan agents search the web and return targets. They WILL flag already-engaged threads as "new targets." **Deduplication is the orchestrator's responsibility, not the scan agent's.**

### After receiving scan results:

1. Compile all recommended target URLs
2. Check each against posted engagement history
3. Remove any already-engaged targets
4. Present only genuinely new targets to the user
5. If a previously engaged target has NEW activity (e.g., the original author replied), note it as "update on existing engagement" — not as a new target

### Scan output files

Store scan results in `tmp/discourse-scan-<date>-<time>.txt` for reference across sessions.

---

## 3. Thread Etiquette — HARD RULES

### One reply per thread

- **ONE substantive reply per thread**, unless the original author or another high-value account directly responds to you
- A direct response from the author makes a follow-up exchange natural and expected
- Posting multiple top-level replies on the same thread looks obsessive and damages credibility

### Same-person limits

- Do NOT engage more than 2 threads by the same person on the same day
- Exception: if they are actively replying to you across threads (genuine conversation)
- With a new account (low follower count), aggressive multi-thread engagement with the same person looks like stalking

### Correction etiquette

- If a high-value target corrects you: acknowledge gracefully, show intellectual honesty
- This BUILDS credibility — academics respect people who update on evidence
- Never double down on a point that was fairly corrected

### Theory positioning

- Do NOT name-drop your theory/framework in cold engagement replies
- Plant conceptual hooks (e.g., "architectural criteria" / "decision procedure") — let people ask
- If someone asks "what criteria?" or "what framework?" — that's the natural opening
- Direct name-drops are for: your own threads, direct questions, academic contexts

---

## 4. Reply Drafting

### Always provide multiple options

Draft 2-3 options per target:
- Option A (recommended): Best balance of substance and length
- Option B: Shorter/sharper alternative
- Option C: Multi-tweet or fuller engagement

### Write drafts to files

Drafts go in `tmp/` (e.g., `tmp/evening-reply-drafts.txt`). Per the console output rule, anything the user needs to copy-paste MUST be in a file opened in Notepad.

### Character awareness

Twitter limit is 280 characters per tweet. Note approximate character count on each draft. If over 280, mark it and offer a trimmed version.

---

## 5. Engagement Strategy — Growth Phase

At low follower counts (<100), organic reach from your own tweets is near zero. The growth strategy is:

1. **Ride high-traffic threads** — your replies are visible to the thread author's audience
2. **Quality over quantity** — one sharp reply beats five mediocre ones
3. **Consistent intellectual identity** — every reply should reinforce the same frame: "the field needs architectural criteria, not behavioral markers or substrate claims"
4. **Engagement begets engagement** — when high-value accounts reply to you, their followers see your profile
5. **Daily cadence matters** — maintain the 14-day posting schedule in `initial-tweets.md` alongside engagement replies

### Target tiers

| Tier | Who | Approach |
|------|-----|----------|
| 1 | Domain researchers (leading academics in your field) | Substantive, precise, deferential but not sycophantic |
| 2 | Science communicators (popular authors, podcasters) | Accessible, bridges pop and academic |
| 3 | Tech/AI figures (lab leaders, industry voices) | Sharp, quotable, positions you as the theory person |
| 4 | Viral/news threads | Corrective, adds depth to shallow discourse |

---

## 6. The Workflow

1. Claude scans discourse and identifies targets
2. Claude cross-references against posted history (THIS IS MANDATORY)
3. Claude drafts replies with multiple options per target
4. User reviews, picks or modifies, posts manually
5. Claude updates engagement tracking in session-context.md

**Claude never posts tweets. The user always posts manually.**

---

## 7. Session Shutdown — Twitter

Before session end:
1. Update all engagement statuses in `session-context.md`
2. Note any pending exchanges (awaiting replies)
3. Note next day's content from `initial-tweets.md`
4. Save any drafted but unposted replies in `tmp/`
