#!/usr/bin/env python3
"""Markdown -> branded DOCX, using `assets/fleet-template.docx`.

    python3 build-docx.py <source.md> <output.docx> ["Document Title"]

How it works: the template is opened as the document, its body is cleared
(keeping `sectPr`), and the markdown is written into it — so styles, the header
logo and the footer page fields survive untouched. The header's title
placeholder is patched afterwards by rewriting the package's header XML, which
python-docx cannot do through its API.

Supported markdown: `#`..`######` headings, `- `/`* ` bullets (two levels),
`> ` blockquotes, GitHub pipe tables, `---` rules, `**bold**`, `*italic*`,
`` `code` ``, and a leading `<!--META ... -->` block which becomes the
document-control table.

Everything about the look lives in `tokens.py`. Nothing here hardcodes a
colour or a size.
"""
import os
import re
import sys
import zipfile
from xml.sax.saxutils import escape as xml_escape

from docx import Document
from docx.oxml.ns import qn
from docx.shared import Mm, Pt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tokens as T  # noqa: E402

TEMPLATE = os.path.join(HERE, "assets", "fleet-template.docx")
TITLE_PLACEHOLDER = "{{DOCUMENT_TITLE}}"

_META = re.compile(r"\s*<!--\s*META\s*(.*?)-->\s*", re.DOTALL)
_INLINE = re.compile(r"\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`")


# ------------------------------------------------------------ inline text ---
def add_runs(paragraph, text, *, italic=False):
    """Write `text` into `paragraph`, honouring **bold**, *italic*, `code`."""
    pos = 0
    for m in _INLINE.finditer(text):
        if m.start() > pos:
            r = paragraph.add_run(text[pos:m.start()])
            r.italic = italic
        bold, ital, code = m.groups()
        if bold is not None:
            r = paragraph.add_run(bold)
            r.bold = True
            r.italic = italic
        elif ital is not None:
            r = paragraph.add_run(ital)
            r.italic = True
        else:
            r = paragraph.add_run(code)
            r.font.name = T.FONT_MONO
            r.italic = italic
        pos = m.end()
    if pos < len(text):
        r = paragraph.add_run(text[pos:])
        r.italic = italic
    return paragraph


# --------------------------------------------------------------- builders ---
class Builder:
    def __init__(self, doc):
        self.doc = doc
        self.counts = {"headings": 0, "bullets": 0, "tables": 0,
                       "paragraphs": 0, "quotes": 0}

    def para(self, text, style=None):
        p = self.doc.add_paragraph(style=style)
        add_runs(p, text)
        self.counts["paragraphs"] += 1
        return p

    def heading(self, text, level):
        p = self.doc.add_paragraph(style=f"Heading {min(level, 3)}")
        add_runs(p, text)
        self.counts["headings"] += 1
        return p

    def bullet(self, text, level=0):
        p = self.doc.add_paragraph(
            style="List Bullet" if level == 0 else "List Bullet 2")
        add_runs(p, text)
        self.counts["bullets"] += 1
        return p

    def blockquote(self, text):
        p = self.doc.add_paragraph(style="Quote")
        p.paragraph_format.left_indent = Mm(6)
        add_runs(p, text, italic=True)
        self.counts["quotes"] += 1
        return p

    def table(self, rows, widths_mm=None, header=True):
        if not rows:
            return None
        cols = max(len(r) for r in rows)
        t = self.doc.add_table(rows=0, cols=cols)
        t.style = "Table Grid"
        t.autofit = False
        tbl_pr = t._tbl.tblPr
        layout = tbl_pr.makeelement(qn("w:tblLayout"), {qn("w:type"): "fixed"})
        tbl_pr.append(layout)
        for i, row in enumerate(rows):
            cells = t.add_row().cells
            for j in range(cols):
                txt = row[j] if j < len(row) else ""
                cell = cells[j]
                cell.text = ""
                p = cell.paragraphs[0]
                add_runs(p, txt)
                if header and i == 0:
                    for r in p.runs:
                        r.bold = True
                if widths_mm and j < len(widths_mm):
                    cell.width = Mm(widths_mm[j])
        self.counts["tables"] += 1
        return t


# ------------------------------------------------------------------ parse ---
def parse_meta(text):
    m = _META.match(text)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or ":" not in line:
            continue
        k, v = line.split(":", 1)
        meta[k.strip()] = v.strip()
    return meta, text[m.end():]


def _is_separator(cells):
    return bool(cells) and set("".join(cells)) <= set("-: ")


def split_row(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def build(src_path, out_path, title=None):
    with open(src_path, encoding="utf-8") as fh:
        raw = fh.read()
    meta, body_text = parse_meta(raw)

    doc = Document(TEMPLATE)
    # clear the body, keep the section properties
    body = doc.element.body
    sect_pr = body.find(qn("w:sectPr"))
    for child in list(body):
        if child is not sect_pr:
            body.remove(child)

    b = Builder(doc)

    # title: explicit argument wins, else the first H1, else the filename
    first_h1 = next((l[2:].strip() for l in body_text.splitlines()
                     if l.startswith("# ")), None)
    doc_title = title or first_h1 or os.path.basename(src_path)
    p = doc.add_paragraph(style="Title")
    add_runs(p, doc_title)

    if meta:
        b.table([[k, v] for k, v in meta.items()],
                widths_mm=[T.META_KEY_W_MM, T.META_VAL_W_MM], header=False)
        doc.add_paragraph("")

    lines = body_text.splitlines()
    i, skipped_h1 = 0, False
    while i < len(lines):
        line = lines[i].rstrip()
        stripped = line.strip()

        if not stripped or stripped.startswith("<!--") or set(stripped) <= {"-"} and len(stripped) >= 3:
            i += 1
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            level, text = len(m.group(1)), m.group(2).strip()
            if level == 1 and not skipped_h1:
                skipped_h1 = True          # duplicates the Title
                i += 1
                continue
            b.heading(text, level)
            i += 1
            continue

        if stripped.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = split_row(lines[i])
                if not _is_separator(cells):
                    rows.append(cells)
                i += 1
            b.table(rows)
            doc.add_paragraph("")
            continue

        if stripped.startswith(">"):
            b.blockquote(stripped.lstrip("> ").strip())
            i += 1
            continue

        m = re.match(r"^(\s*)[-*]\s+(.*)$", line)
        if m:
            indent = len(m.group(1))
            b.bullet(m.group(2).strip(), level=1 if indent >= 2 else 0)
            i += 1
            continue

        b.para(stripped)
        i += 1

    body.remove(sect_pr)
    body.append(sect_pr)
    doc.save(out_path)
    _patch_header(out_path, doc_title, meta)
    return doc_title, b.counts


def _patch_header(path, title, meta):
    """Replace the header/footer placeholders inside the saved package."""
    repl = {
        TITLE_PLACEHOLDER: title,
        "{{STATUS}}": meta.get("Status", ""),
        "{{VERSION}}": (f"Version: {meta['Version']}" if meta.get("Version") else ""),
    }
    tmp = path + ".tmp"
    with zipfile.ZipFile(path) as zin, \
            zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename.startswith(("word/header", "word/footer")):
                txt = data.decode("utf-8")
                for k, v in repl.items():
                    txt = txt.replace(k, xml_escape(v))
                data = txt.encode("utf-8")
            zout.writestr(item, data)
    os.replace(tmp, path)


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    src, out = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else None
    if not os.path.exists(TEMPLATE):
        print(f"missing {TEMPLATE} — run make-template-docx.py first",
              file=sys.stderr)
        return 1
    doc_title, counts = build(src, out, title)
    size = os.path.getsize(out)
    print(f"built: {out}  ({size:,} bytes)  title={doc_title!r}")
    print("       " + "  ".join(f"{k}={v}" for k, v in counts.items()))
    if size < 5000:
        print("WARNING: suspiciously small output", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
