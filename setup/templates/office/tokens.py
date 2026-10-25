"""Agent Fleet office design tokens — the single source for every builder.

Change a value here and every DOCX, PDF and deck follows. Nothing else in this
directory may hardcode a colour, a font name or a page dimension.

Palette family: teal-blue primary with a fresh-green accent. Deliberately its
own hue family — do not copy an employer's or client's brand colours into this
file. To brand a fork, replace the values here and swap `assets/logo.svg`.
"""

# ---------------------------------------------------------------- colour ----
# Hex without '#'. Roles, not names — call it PRIMARY, never "teal".
PRIMARY      = "12707F"  # headings, title bars, rules, links
PRIMARY_DEEP = "0A3D46"  # cover gradients, deep navy text on light
PRIMARY_SOFT = "3E97A6"  # secondary accent, inactive states
ACCENT       = "4F9D3A"  # positive accent, "now"/active markers

INK          = "1A1F24"  # body text
MUTED        = "5B6670"  # sub-text, captions, footers
FAINT_INK    = "8A959D"  # source lines, disabled

SURFACE      = "FFFFFF"  # page/slide background
SURFACE_TINT = "EEF6F7"  # card fill on-brand
SURFACE_MUTE = "F4F6F7"  # card fill neutral
BORDER       = "CBDDE1"  # card and image borders
BORDER_MUTE  = "E3E7EA"

OK           = "2E7D32"  # semantic only — not the brand accent
WARN         = "B26A00"
ERROR        = "C0392B"

# ------------------------------------------------------------------ type ----
# Generic, metrically-common families. No licensed or brand typeface.
FONT_BODY    = "Arial"            # Liberation Sans is the metric-compatible Linux twin
FONT_HEAD    = "Arial"
FONT_MONO    = "Courier New"
# CSS stack for HTML-rendered slides
FONT_STACK   = ("-apple-system, 'Segoe UI', Roboto, 'Liberation Sans', "
                "Helvetica, Arial, sans-serif")
FONT_STACK_MONO = "ui-monospace, SFMono-Regular, Menlo, 'DejaVu Sans Mono', monospace"

# ------------------------------------------------------- document layout ----
# True A4. (Mixing A4 width with Letter height is a common template defect —
# it prints short on Letter and clips on A4. Decide once, here.)
PAGE_W_MM      = 210.0
PAGE_H_MM      = 297.0
MARGIN_TOP_MM  = 32.5   # room for the header block + logo
MARGIN_SIDE_MM = 25.0
MARGIN_BOT_MM  = 15.0
HEADER_MM      = 12.5
FOOTER_MM      = 14.7
TEXT_W_MM      = PAGE_W_MM - 2 * MARGIN_SIDE_MM   # 160.0

# Doc-control table column widths (must sum to <= TEXT_W_MM)
META_KEY_W_MM  = 45.0
META_VAL_W_MM  = 110.0

# Point sizes
PT_TITLE   = 28
PT_H1      = 14
PT_H2      = 12
PT_H3      = 11
PT_BODY    = 11
PT_SMALL   = 8    # header / footer

# --------------------------------------------------------- slide layout ----
SLIDE_W_IN = 13.333          # 16:9
SLIDE_H_IN = 7.5
CANVAS_W   = 1920            # HTML render canvas, px
CANVAS_H   = 1080
PAD_V      = 120             # slide padding, px
PAD_H      = 150

# Logo — 4:1 wordmark, sized to sit flush-right in the DOCX header
LOGO_SVG     = "assets/logo.svg"
LOGO_PNG     = "assets/logo.png"
LOGO_W_MM    = 28.3
LOGO_H_MM    = 7.1


def hexes():
    """Every colour token as {name: 'RRGGBB'} — used by the tests."""
    return {k: v for k, v in globals().items()
            if k.isupper() and isinstance(v, str) and len(v) == 6
            and all(c in "0123456789ABCDEFabcdef" for c in v)}
