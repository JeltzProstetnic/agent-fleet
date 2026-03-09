# Document Management Guide

## Purpose

Documents produced during sessions (drafts, letters, reports, PDFs) need durable, cross-machine-accessible storage. Project `tmp/` directories are for throwaway artifacts only.

## Recommended Setup

Choose a storage backend accessible from all machines:

| Option | How | Best for |
|--------|-----|----------|
| **Cloud sync** | Dropbox, Google Drive, OneDrive | Personal use, small teams |
| **NAS** | Synology, TrueNAS, QNAP | Home lab, large files |
| **Git repo** | Dedicated `dms/` repo | Version-controlled documents |

## Convention

1. **Catalog every document** — maintain an index (e.g., `catalog.md`) with date, title, type, and storage path
2. **Use consistent naming** — `YYYY-MM-DD_type_description.ext` (e.g., `2026-03-09_letter_contract-cancellation.pdf`)
3. **Never store in `tmp/`** — if a document needs to survive the session, it needs durable storage
4. **Cross-machine rule** — documents must be findable from any machine from the moment they exist

## Integration with Agent Fleet

Add a `dms/` directory to your config repo or a separate repository. Reference it in your project CLAUDE.md if you want the agent to manage document intake automatically.

The agent should:
- Create documents in the designated storage location
- Add catalog entries on creation
- Never leave user-facing documents only in conversation context — persist to files immediately
