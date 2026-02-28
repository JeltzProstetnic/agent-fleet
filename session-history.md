# Session History

Rolling window of the last 3 sessions. Newest first.

### 2026-02-28 — SteamDeckBedroom (steamdeck)
**Goal:** Deploy encrypted vault to Steam Deck for MCP token provisioning
**Completed:**
- Pulled 2 new commits (pipefail + SteamOS fixes)
- Fixed secrets/.gitignore to allowlist vault.json.enc
- Wrote inbox task for WSL to commit vault.json.enc
**Key Decisions:**
- vault.json.enc is now allowlisted in secrets/.gitignore so it can be tracked in git
**Pending at shutdown:** Waiting for WSL session to pick up inbox task
**Recovery/Next session:**
Next session on this Deck: check if WSL has pushed vault.json.enc. If so, `git pull && bash secrets/vault-manage.sh deploy` (will prompt for passphrase).


