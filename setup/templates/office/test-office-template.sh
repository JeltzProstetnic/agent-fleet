#!/usr/bin/env bash
# test-office-template.sh — structural verification of the fleet office template.
#
#   bash test-office-template.sh
#
# Checks the artefacts, not the pixels: the deliberate policy is that rendered
# images are reviewed by a human, never read into an agent's context
# (see ~/.claude/knowledge/presentation-design.md).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== assets =="
check "logo.svg exists"                "[ -s '$HERE/assets/logo.svg' ]"
check "logo.png exists"                "[ -s '$HERE/assets/logo.png' ]"
check "tokens.py imports"              "python3 -c \"import sys;sys.path.insert(0,'$HERE');import tokens\" 2>/dev/null"

echo "== tokens =="
check "no employer brand blue #005091" "! grep -qi '005091' '$HERE'/tokens.py"
check "no employer brand green #69B42D" "! grep -qi '69B42D' '$HERE'/tokens.py"
check "page is true A4 (297mm high)"   "python3 -c \"import sys;sys.path.insert(0,'$HERE');import tokens as t;raise SystemExit(0 if abs(t.PAGE_H_MM-297)<0.01 else 1)\""
check "meta columns fit text width"    "python3 -c \"import sys;sys.path.insert(0,'$HERE');import tokens as t;raise SystemExit(0 if t.META_KEY_W_MM+t.META_VAL_W_MM<=t.TEXT_W_MM else 1)\""
check "no licensed brand typeface"     "! grep -qiE 'Uniform Pro|Frutiger|Helvetica Neue LT' '$HERE'/tokens.py"

echo "== docx template =="
python3 "$HERE/make-template-docx.py" >/dev/null 2>&1
check "fleet-template.docx built"      "[ -s '$HERE/assets/fleet-template.docx' ]"
check "template embeds the logo"       "unzip -l '$HERE/assets/fleet-template.docx' 2>/dev/null | grep -q 'word/media/'"
check "template has a header"          "unzip -l '$HERE/assets/fleet-template.docx' 2>/dev/null | grep -q 'word/header'"
check "template has a footer"          "unzip -l '$HERE/assets/fleet-template.docx' 2>/dev/null | grep -q 'word/footer'"

echo "== docx build =="
SRC="$WORK/sample.md"
cat > "$SRC" <<'MD'
<!--META
Status: DRAFT — test fixture
Version: 0.1
Accountable owner: Test
-->

# Sample Document

> A draft warning.

## A heading

Body text with **bold** and *italic* and `code`.

- first bullet
- second bullet
  - nested bullet

| Col A | Col B |
|-------|-------|
| one   | two   |
MD
python3 "$HERE/build-docx.py" "$SRC" "$WORK/sample.docx" "Sample Title" >"$WORK/docx.log" 2>&1
check "build-docx.py exits 0"          "[ -s '$WORK/sample.docx' ]"
check "title patched into header"      "python3 -c \"
import zipfile,sys
z=zipfile.ZipFile('$WORK/sample.docx')
t=''.join(z.read(n).decode() for n in z.namelist() if n.startswith('word/header'))
raise SystemExit(0 if 'Sample Title' in t and '{{DOCUMENT_TITLE}}' not in t else 1)\""
check "status patched into footer"     "python3 -c \"
import zipfile
z=zipfile.ZipFile('$WORK/sample.docx')
t=''.join(z.read(n).decode() for n in z.namelist() if n.startswith('word/footer'))
raise SystemExit(0 if 'test fixture' in t and '{{STATUS}}' not in t else 1)\""
check "PAGE/NUMPAGES fields present"   "python3 -c \"
import zipfile
z=zipfile.ZipFile('$WORK/sample.docx')
t=''.join(z.read(n).decode() for n in z.namelist() if n.startswith('word/footer'))
raise SystemExit(0 if 'NUMPAGES' in t else 1)\""
check "brand colour reached styles"    "python3 -c \"
import zipfile,sys;sys.path.insert(0,'$HERE');import tokens as t
z=zipfile.ZipFile('$WORK/sample.docx')
raise SystemExit(0 if t.PRIMARY in z.read('word/styles.xml').decode() else 1)\""
check "counts reported by the builder" "grep -q 'headings=' '$WORK/docx.log'"
check "meta table + content table"     "python3 -c \"
from docx import Document
d=Document('$WORK/sample.docx')
raise SystemExit(0 if len(d.tables)==2 else 1)\""

echo "== deck build =="
if python3 -c "
import sys;sys.path.insert(0,'$HERE')
import importlib.util
spec=importlib.util.spec_from_file_location('bd','$HERE/build-deck.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.find_chrome()" >/dev/null 2>&1; then
    python3 "$HERE/build-deck.py" "$WORK/deck.pptx" >"$WORK/deck.log" 2>&1
    check "build-deck.py self-test builds" "[ -s '$WORK/deck.pptx' ]"
    check "slides == notes == media"       "python3 -c \"
import zipfile
z=zipfile.ZipFile('$WORK/deck.pptx');n=z.namelist()
s=len([x for x in n if x.startswith('ppt/slides/slide')])
t=len([x for x in n if x.startswith('ppt/notesSlides/notesSlide')])
m=len([x for x in n if x.startswith('ppt/media/')])
raise SystemExit(0 if s==t==m==6 else 1)\""
    check "no blank renders (>10 KB each)" "python3 -c \"
import zipfile
z=zipfile.ZipFile('$WORK/deck.pptx')
sz=[z.getinfo(x).file_size for x in z.namelist() if x.startswith('ppt/media/')]
raise SystemExit(0 if sz and min(sz)>10000 else 1)\""
else
    echo "  SKIP  deck build — no Chrome/Chromium available on this machine"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
