# Output & Delivery Rules

**Load this file when:** generating documents, PDFs, copy-paste content, or when a subagent produces files.

## PDF Output Rule

Any document, summary, or one-pager MUST be delivered as **PDF**, not markdown. The user does not read `.md` files. Write the `.md` as source, convert to PDF, open the PDF:
- **Convert (preferred — weasyprint)**: `pandoc input.md -o input.html --standalone && weasyprint input.html output.pdf`
- **Convert (fallback — xelatex, if installed)**: `pandoc input.md -o output.pdf --pdf-engine=xelatex -V geometry:margin=1.8cm -V mainfont="Liberation Sans" -V monofont="Liberation Mono" --highlight-style=tango`
- **Before converting**: verify which engine is available (`which weasyprint xelatex`). Do NOT guess — check first.
- **Avoid** Unicode box-drawing characters in code blocks (xelatex chokes) — use tables instead
- **weasyprint HTML: BMP symbols only** — never use emoji codepoints (U+1F000+) in HTML for weasyprint. Emoji fonts aren't portable across machines. Use BMP Unicode symbols instead: `&#10004;` (checkmark), `&#9654;` (play), `&#9733;` (star), `&#9679;` (bullet). For colored indicators: `<span style="color:green">&#9679;</span>`.
- **Open (WSL)**: `powershell.exe -Command "Start-Process '$(wslpath -w /absolute/path/to/file)'"` — ALWAYS use `wslpath -w` to convert; never manually construct `\\wsl.localhost\` paths (error-prone escaping)
- **Open (native Linux)**: `xdg-open output.pdf`
- **Detect environment**: if `/mnt/c/` exists → WSL, otherwise → native Linux
- Short text (<10 words) can go inline. Anything longer → file + PDF + open.

## Copy-Paste Content Exception

Tweet drafts, reply options, and anything the user needs to copy-paste goes in plain text (`.md` or `.txt`, not PDF). Use single-line paragraphs — NO hard line breaks mid-sentence. Wrapped lines look nice in terminal but break copy-paste. Rules:
- **One piece of content per file** (e.g., `tmp/bradford-tweet.txt` not a mega-file). Keep the file minimal — just the copy-pastable text, no headers/context/dividers.
- **Open in editor** after writing — same platform detection as PDFs: WSL → `powershell.exe -Command "Start-Process '$(wslpath -w /path)'"`, native Linux → `xdg-open /path`, VPS → termbin (no editor). Overwriting a file already open is fine — editors auto-reload.
- **Never claim a file has been updated without a tool call.** If you say "I've updated the file" you must have an Edit or Write tool result confirming it.

## Email Draft Rule

Email drafts go to Gmail Drafts via `draft_gmail_message` MCP tool, never to any file. The Gmail draft is the workspace — it's editable, sendable, and doesn't create orphan files.

## Subagent File Delivery Rule

When a subagent (Task tool) produces a file (PDF, image, etc.), do NOT open it again in the parent context. **Check procedure — run BEFORE any file-open command:**
1. Scan the subagent's returned output for open/delivery commands (`Start-Process`, `xdg-open`, `open`, or any shell command targeting the file).
2. If found → file already delivered. Do nothing.
3. If NOT found → subagent created but didn't open the file. Only then may the parent open it.
4. When in doubt, do NOT open — a missing open is a minor annoyance, a duplicate open is a visible bug.
