# System Tools Catalog

Per-machine inventory of CLI tools, packages, and capabilities.
Consult before running tool-dependent commands.

**Last updated by:** `audit-tools.sh` — re-run after installing/removing software.
**Script:** `~/agent-fleet/setup/scripts/audit-tools.sh --update <this-file>`

## your-machine (your-os)
[Run `bash ~/agent-fleet/setup/scripts/audit-tools.sh --update ~/.claude/reference/system-tools.md` to populate this section]

---

## Recipes

### Mermaid-to-PDF Pipeline

Renders `.mmd` diagram files to a multi-page landscape PDF. Requires: `mmdc`, `weasyprint`, `python3`.

1. **Write .mmd files** — one per diagram, plain Mermaid syntax + optional `style` directives
2. **Render PNGs** — `mmdc -i input.mmd -o output.png -w 1600 -H 900 -b white -t neutral`
3. **Compose HTML** — base64-embed PNGs (`data:image/png;base64,...`), use `@page { size: 297mm 210mm; }` for landscape, `page-break-after: always` per diagram
4. **Convert to PDF** — `weasyprint input.html output.pdf`

Key flags: `-w`/`-H` control PNG resolution, `-t neutral` for clean theme, `-b white` for white background.
