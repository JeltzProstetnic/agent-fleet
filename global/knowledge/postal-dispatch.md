<!-- consumed-by: any project sending a physical letter -->

# Postal dispatch — sending a real letter from an agent

**Load when:** a project needs a physical letter delivered — `Brief`, `Einschreiben`, an authority
submission, anything where an e-mail will not do. Everything here is **measured on the live portal**,
not read off a marketing page.

**Capability status: WORKING.** First letter dispatched end-to-end 2026-09-23 (life, `LIFE-17`):
Art.-15-DSGVO request to a company, `Brief-Einschreiben`, order `TG-5855059`, 6,07 € incl.

---

## The product: EinfachBrief

`https://www.einfach-brief.at/fe/` — Österreichische Post's PDF-upload → print → envelope → frank →
post service, operated by **sendhybrid ÖPBD GmbH**, Göstinger Straße 213, 8051 Graz. Upload a PDF,
Post does the rest. Free registration, no business contract needed.

**Account:** login `<your EinfachBrief account e-mail>`. Password in the fleet vault under key
**`einfachbrief`**. **The agent enters the password itself — no human step**. The only constraint is HOW: through the `/dev/shm` bridge in `knowledge/dev-browser-ops.md`, **never `browser_type`**, which would put the value in the transcript as a tool argument and break the fleet's *never print or record a credential's value* rule by construction. See trap 4 below — the snapshot leaks it too.. This is a deliberate exception to the vault rule
that browser logins are out of scope: EinfachBrief has **no API**, so the browser login *is* the
automation credential. Precedent: `homeassistant_web`.

**What instrument to use:**
- **`Einschreiben`** for anything needing proof — authority submissions, DSGVO requests, deadlines.
- **RSa/RSb are authority-only.** A private sender cannot send them; do not look for the option.
- Plain `Brief` for everything else.

---

## ⛔ The five traps, in the order they bite

### 1. The address block is NOT generic DIN 5008 — wrong geometry is silently rejected

EinfachBrief uses its own template. Measured from their own `.docx`
(`EinfachBrief-Vorlage-Musterbrief_Einschreiben.docx`, `w:framePr`, `anchorLock="1"`):

| Frame | x | y | w | h |
|---|---:|---:|---:|---:|
| **Anschriftenfeld (recipient)** | **24.9 mm** | **71.7 mm** | 85.0 mm | 32.1 mm |
| Absender | 50.8 mm | 19.0 mm | 116.2 mm | 15.4 mm |

Proven both directions by their own parser:

| Recipient block at | Their verdict |
|---|---|
| 50.3 mm / 20.1 mm (DIN 5008 Form B) | **`Stück: 0`**, `0,00 €`, `Senden` disabled |
| 78.2 mm / 27.0 mm (their template) | **`Stück: 1`**, priced, `Senden` enabled |

⛔ **There is no error message.** A rejected letter shows quantity 0 and price 0, which reads exactly
like a page still loading. **Always assert `Stück >= 1` before believing an upload worked.**
Reference builder that asserts the geometry after rendering:
`~/life/drafts/build-art15-vivacios.py` (weasyprint → PDF → PyMuPDF assertions).

### 2. Read `Gesamtpreis`, never a row — the cart is server-side and survives everything

The cart is **account state**, not browser state. It survives logout, browser restart and days.
"The browser session is gone" does not mean the cart is gone — **always inspect `Offene Sendungen`
before adding anything.**

⛔ **Unticking a row is not cleaning it — only deletion is.** Measured across three consecutive days
on the same account: a session unticked two stale rows and recorded the cart as clean; **on the next
login all three rows were ticked again** and `Gesamtpreis` read `17,15 €` — three copies of one
letter. Three sessions in a row inferred the total from a single row and were wrong every time
(€6,85 claimed, €11,44 measured, €17,15 measured).

**Delete stale rows.** The row controls are unlabelled SVGs with no `aria-label` and no text —
identify them by the first characters of their `path d`:

| `d` starts with | Control |
|---|---|
| `m18.168 8.716-8.4 8.4L6 13.372…` | tick — row is selected (present only when ☑) |
| `m22.17 4.43-2.09-2.08a2 2 0 0 0-2.83 0L4.08 1…` | pencil (edit) |
| `M5 6H3v2h1.13l1.68 11.78A2.61 2.61 0 0 0 8.37…` | **trash (delete)** |

Delete is immediate, no confirmation, no undo; the table re-renders after each click, so **re-find
the row each time** rather than reusing a reference list. ⚠ Do not read selection state from
`input[type=checkbox]` — that list also contains the cookie banner's boxes.

### 3. Hard `/fe/*` navigation 404s

`https://www.einfach-brief.at/fe/login` returns **404**. It is a SPA with no server routes: load
**`/fe/`** and let it route, then wait ~3 s for the form to replace `Loading…`. A `401` on
`/be/users/v1` in the console is just "not logged in yet", not a fault.

### 4. ⛔ The accessibility snapshot leaks the password

Chrome autofills the login form, and **`browser_snapshot` returns password-field values in clear
text**. The old protection — *"the agent types the e-mail, the human types the password"* (superseded 2026-10-20 for vault-held credentials, see `knowledge/dev-browser-ops.md`) — is
useless the moment the browser prefills, because the agent receives the value without asking.

⇒ **Clear the password field before snapshotting a login page, or do not snapshot it at all** —
click `Login` via `browser_evaluate` and inspect only the page after login.

### 5. ⛔⛔ Payment: 3-D Secure CANNOT complete in an automated browser

**This is the one that stops the flow, and it costs a real declined transaction to learn.**

Measured 2026-09-23. The card tokenised fine (`secure.ixopay.com/…/tokenize/creditcard → 200`), then:

```
Permissions policy violation: payment is not allowed in this document.
  @ https://3dspayment.paylife.at/challengeRequestBrowser
```

The 3-D Secure challenge runs in a cross-origin iframe that is not granted the `payment`
Permissions-Policy feature, so the SCA step cannot execute and the issuer declines:

```
message "General decline"  code 2003  transactionFinished:false  paymentCompletedOn:null
```

⚠ **`paymentCompleted: true` in that payload does NOT mean success** — it means the flow finished
running. The field that decides is **`transactionFinished`**, plus a non-null `paymentCompletedOn`.

⛔ **Do not "fix" this by injecting `allow="payment"` into the iframe.** That is a payment-
authentication control; defeating it is out of bounds.

⇒ **Filling the card number for the user does not help** — the wall is the 2FA, not the data entry.

⚠ **Do not over-read the mechanism.** What is *measured* is the permissions-policy violation and the
decline. The same account, same card and same page went through minutes later in the user's ordinary
Chrome — so the challenge either was not demanded there at all, or ran normally. The likely full
story is risk-based: **the automated browser looks risky, the issuer demands a step-up, and the
step-up is exactly what cannot execute.** That is an inference, not a measurement. The operational
conclusion is unaffected either way: do not attempt card payment from the automated browser.

**Working division of labour:** the agent does everything up to and including `Senden`, then the
human opens the portal in their **normal browser** and pays; the cart is server-side, so nothing is
lost in the handover. This is what worked on 2026-09-23.

**The real fix for volume: `Sammelrechnung`** (monthly invoice, needs an application to Post).
It removes per-letter SCA entirely and makes the flow fully agent-drivable. Keep a confirmation step
on our side instead of at the card terminal.

ℹ️ Their own post-payment redirect targets `/fe/wizard/finish` (one `z`) while the app lives at
`/fe/wizzard` (two `z`) — a **404 on every outcome, success included**. Their bug. Do not read that
404 as a failed payment; read the order list.

---

## The wizard, step by step

`/fe/wizzard` — **1 Versandoptionen → 2 Dokumente hochladen → 3 Bestätigen & Versenden → 4 Zahlung.**

**Step 1** — `button "Einzelbrief" | "Serienbrief" | "Adressierte Werbesendung"`, then radiogroups
reachable by accessible name. ⚠ **The defaults cost money on a plain text letter:**

| Group | Options | Default |
|---|---|---|
| Layout | `Einseitig` / `Beidseitig` | **Beidseitig** |
| Druck | `Schwarz & Weiß` / `Farbe` | **Farbe** |
| Versandart | `Premium Brief` / `Brief` | **Premium Brief** |
| Zusatzleistungen | ☐ `Einschreiben` ☐ `E-Brief` | both off |

Advance with `button "Weiter mit Einzelbrief"`.

ℹ️ **There are no Einschreiben tiers here** — just the one `Einschreiben` checkbox. No
*Eigenhändig*, no *Übernahmeschein*. Older research listing three tiers describes the counter tariff,
not EinfachBrief. *"Einfaches Einschreiben"* = this one box.

**Step 2** — two drop zones (`Hauptdokument`, `Beilage`), each with its own `input[type=file]`
(main first). `Weiter` stays disabled until a file lands. **PDF only**, max **14 sheets** per
envelope (14 simplex / 28 duplex), C5 window envelope. ⚠ `button "Datei auswählen"` is **not**
matchable by exact text — click the `input[type=file]` directly, which still raises the chooser.

**Step 3** — the table plus `Gesamtpreis exkl. Mwst.` and `Senden` (disabled while `Stück` is 0).

**Step 4 `Zahlung`** — see trap 5.

**Cut-off:** submitted before **17:00** → processed next working day → posted as PRIO the working day
after (Sat excluded).

---

## Price, measured (1 page, einseitig, S/W)

| Versandart | Druck | Porto | exkl. | **incl. 20 %** |
|---|---:|---:|---:|---:|
| `Premium Brief` + Einschreiben | 0,31 € | 5,40 € | 5,71 € | 6,85 € |
| **`Brief` + Einschreiben** | 0,31 € | **4,75 €** | **5,06 €** | **6,07 €** |

The Premium surcharge is **postage**, not print, and buys next-working-day delivery.
**Default choice: plain `Brief` + `Einschreiben`.**

---

## Recipe for the PDF

`@page { size: A4; margin: 20mm 20mm 25mm 20mm }`, then a fixed-height `.head` block (~78.4 mm)
holding sender line / address / info absolutely positioned inside it, so flowing body text starts at
~98.4 mm from the page top. Body 9.8 pt / line-height 1.32 fits a one-page letter.

⚠ **Two build defects that only surface on inspection, never as an error:**
1. Absolutely positioning the *body* silently clips the signature off the page bottom.
2. Too little bottom clearance puts text in the franking zone — assert numerically (≥20 mm).

**Always assert the rendered artifact**, not the source: page count, A4 size, recipient block
position, bottom clearance.

---

## Rules

- **Never write a full card number (PAN) to disk, to the vault, or to any tracked file.** Payment
  card data is entered live into the payment page and nowhere else.
- **The human pays** unless `Sammelrechnung` is active. Never enable Sammelrechnung without the
  user's explicit decision — it removes the per-letter release gate.
- **After payment, capture the order ID and the Einschreiben tracking number into the DMS.** The
  Aufgabebeleg is the proof of dispatch that a deadline argument rests on. Order ID appears
  immediately in `Auftragsliste`; the tracking number only after Post processes the batch.
- **A letter carrying a legal deadline gets its dispatch date recorded the same session it is sent.**

## post.at tracking account (separate from EinfachBrief)

**Account:** login `<your post.at account e-mail>`. Password in the fleet vault under key **`post_at`**
(login/password/deploy_to), filled via the `/dev/shm` bridge — proven 2026-11-04.

**Tracking hides the sender.** The "Absender*in anzeigen" link opens a login dialog, and even logged
in, post.at shows **no sender** for a letter that is not linked to the account (e.g. `RH965410707AT`).
"Meine Sendungen" lists only parcels addressed to the account's own address — it is not a general
sender lookup.

**The Post's "Rückscheinbriefe der Ämter und Behörden" terms** (Ausgabe 1/2026 + 2/2026) make the
Post the **Art. 28 GDPR processor** for ID data collected at RSa/RSb pickup, with Postpartner shops
as sub-processors. Copies in `~/life/knowledge/legal/sources/`.

(life WSL 2026-11-04)

## Alternatives, if EinfachBrief is ever unavailable

- **Pingen** (`pingen.com`) — real REST API, lists Austria. Confirm AT-Einschreiben support first.
- **sFTP** — Post's official automation channel, but needs a payment agreement and bypasses the
  human gate.
- LetterXpress is Germany-only. Not suitable.
