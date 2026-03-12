# Document Management Guide

## Purpose

Documents produced during sessions (drafts, letters, reports, PDFs) need durable, cross-machine-accessible storage. Project `tmp/` directories are for throwaway artifacts only — anything the user needs to keep must go through document management.

## Quick Start

### 1. Choose a Storage Backend

| Option | How | Best for |
|--------|-----|----------|
| **Cloud sync** | Dropbox, Google Drive, OneDrive | Personal use, small teams |
| **NAS** | Synology, TrueNAS, QNAP | Home lab, large files |
| **Git repo** | Dedicated `dms/` repo | Version-controlled documents |

You can combine these — e.g., NAS as primary storage with Dropbox sync for mobile access.

### 2. Set Up Directory Structure

Create a `dms/` directory in your config repo:

```
dms/
  catalogs/           # Document indexes by category
    financial.md
    legal.md
    academic.md
    personal.md
  scripts/            # Automation
    dms-file.sh       # Filing helper
    dms-validate.sh   # Catalog validation
  naming-convention.md
  storage-map.md
  intake-protocol.md
  README.md
```

### 3. Define a Naming Convention

Use a consistent ID format for all documents:

```
<CATEGORY>-<SEQ>    e.g., FIN-042, LEG-007, ACA-015
```

Recommended category prefixes:

| Prefix | Category | Examples |
|--------|----------|----------|
| `FIN` | Financial | Invoices, tax forms, bank statements |
| `LEG` | Legal | Contracts, complaints, court documents |
| `ACA` | Academic | Papers, certificates, transcripts |
| `MED` | Medical | Reports, prescriptions, insurance |
| `PER` | Personal | Identity docs, correspondence |
| `REF` | Reference | Manuals, guidelines, specs |

### 4. Define Storage Locations

Create a `storage-map.md` that maps aliases to physical paths:

```markdown
| Alias | Path | Machine | Notes |
|-------|------|---------|-------|
| `nas` | `smb://nas.local/documents/` | all | Primary storage |
| `dropbox` | `~/Dropbox/DMS-Sync/` | all | Cloud sync mirror |
| `local` | `~/Documents/DMS/` | laptop | Working copies |
```

### 5. Create Catalog Files

Each catalog file is a markdown table:

```markdown
# Financial Documents

| ID | Date | Title | Storage | Path | Backup |
|----|------|-------|---------|------|--------|
| FIN-001 | 2026-01-15 | Invoice CloudProvider Jan | nas | financial/FIN-001_invoice_cloud-jan.pdf | dropbox |
| FIN-002 | 2026-02-01 | Tax return 2025 | nas | financial/FIN-002_tax-return-2025.pdf | dropbox |
```

### 6. File Naming on Disk

Use: `YYYY-MM-DD_type_description.ext`

Examples:
- `2026-03-09_letter_contract-cancellation.pdf`
- `2026-01-15_invoice_cloud-jan.pdf`
- `2026-02-28_certificate_aws-architect.pdf`

## Document Importance Tiers

| Tier | Examples | Handling |
|------|----------|----------|
| **0 — Critical** | Passport, identity docs, legal drafts, financial/money docs, active complaints, contracts | Store + backup immediately. Never leave only in `tmp/`. |
| **1 — Important** | Certificates, academic papers, correspondence, reports | Store within the session. Backup within 24h. |
| **2 — Reference** | Guidelines, manuals, reference material | Catalog entry. Backup at convenience. |

## Drop Zones and Intake

Set up a drop zone (e.g., `~/dms-inbox/`) where documents land before filing:

1. Documents arrive in drop zone (downloads, session outputs, scans)
2. Agent or user classifies: category, tier, title
3. Filing script assigns ID, renames, moves to storage, adds catalog entry
4. Validation script confirms catalog integrity

A SessionStart hook can scan the drop zone and alert on pending files.

## Integration with Agent Fleet

### CLAUDE.md Configuration

Add a conditional trigger for document management:

```markdown
| Trigger | File |
|---------|------|
| Documents, PDFs, file delivery | `dms/README.md` |
```

### Agent Behavior Rules

The agent should:
- **Create documents** in the designated storage location, never in `tmp/`
- **Add catalog entries** on creation — every document gets indexed
- **Never leave documents only in conversation context** — persist to files immediately
- **Apply the right tier** — critical documents get immediate backup
- **Use consistent naming** — follow the naming convention without exception
- **Check the drop zone** when reminded by hooks or user request

### Output Rules

Configure `output-rules.md` to enforce:
- Documents meant for the user → PDF format
- Copy-paste content → plain text file
- Everything goes through DMS intake

## Validation

Create a validation script that checks:
- All catalog entries have valid IDs (sequential, no gaps)
- Referenced files exist at their declared storage location
- No orphaned files (exist on disk but not in catalog)
- Backup column is filled for Tier 0 and Tier 1 documents

Run validation as part of your regular maintenance routine.

## Backup Strategy

Follow the 3-copy rule for critical documents:
1. **Primary** — NAS or cloud storage
2. **Sync copy** — Dropbox/Drive/OneDrive
3. **Offline copy** — External drive, rotated periodically

Track backup status in catalog files. Validation should flag documents missing required backup copies based on their tier.
