#!/usr/bin/env python3
"""Render a preview card per theme as SVG, for the README.

Run from repo root:  python tools/make-svg-previews.py
Writes docs/previews/<slug>.svg

Colours come from the same .conf files install.ps1 reads, so a README preview
cannot drift from what actually gets installed.
"""
import json
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

NON_THEME = {"ACTIVE_COLOUR_SET", "ACTIVE_LANG"}

# Same token -> candidate style names as install.ps1's $StyleAliases.
ALIASES = {
    "Default": ("Default",),
    "Keyword": ("Keyword", "User keyword"),
    "String": ("String", "Character"),
    "Number": ("Number",),
    "Operator": ("Operator", "Default"),
    "Preprocessor": ("Preprocessor", "Keyword"),
    "Comment": ("Comment (normal)", "Comment line (normal)", "Comment",
                "Comment (documentation)", "Comment line (documentation)",
                "Comment (inactive)"),
}

SNIPPET = [
    [("Preprocessor", "#include <stdio.h>")],
    [],
    [("Comment", "// dark mode, finally")],
    [("Keyword", "int"), ("Default", " main"), ("Operator", "() {")],
    [("Default", "    printf"), ("Operator", "("), ("String", '"hello"'),
     ("Operator", ");")],
    [("Keyword", "    return"), ("Number", " 0"), ("Operator", ";")],
    [("Operator", "}")],
]

CHAR_W = 8.4        # advance width of the 14px monospace stack below
LINE_H = 20
PAD_X = 14
PAD_Y = 16
COLS = 30
FONT = ("ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, "
        "'Liberation Mono', monospace")


def palette(path):
    root = ET.parse(path).getroot()
    sets = root.find("editor/colour_sets")
    theme = next(t for t in sets if t.tag not in NON_THEME)
    lex = theme.find("cc")
    if lex is None:
        lex = theme.find("java")
    pal = {}
    for st in lex:
        n = st.find("NAME/str")
        if n is None or not n.text:
            continue
        name = n.text.strip()
        if name in pal:
            continue
        entry = {}
        for kind in ("FORE", "BACK"):
            c = st.find(kind + "/colour")
            if c is not None:
                entry[kind] = "#%02x%02x%02x" % tuple(int(c.get(k)) for k in "rgb")
        pal[name] = entry
    return pal


def colour(pal, token, fallback):
    for name in ALIASES.get(token, (token,)):
        got = pal.get(name, {}).get("FORE")
        if got:
            return got
    return fallback


def render(slug, name, pal, outdir):
    fg = pal.get("Default", {}).get("FORE", "#dddddd")
    bg = pal.get("Default", {}).get("BACK", "#1e1e1e")

    width = int(COLS * CHAR_W + PAD_X * 2)
    height = int(len(SNIPPET) * LINE_H + PAD_Y * 2)

    rows = []
    for i, row in enumerate(SNIPPET):
        if not row:
            continue
        y = PAD_Y + i * LINE_H + 14
        spans, col = [], 0
        for token, text in row:
            x = PAD_X + col * CHAR_W
            spans.append(
                '<text x="%.1f" y="%d" fill="%s" xml:space="preserve">%s</text>'
                % (x, y, colour(pal, token, fg), escape(text))
            )
            col += len(text)
        rows.append("    " + "\n    ".join(spans))

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}"
     viewBox="0 0 {width} {height}" role="img" aria-label="{escape(name)} theme preview">
  <title>{escape(name)}</title>
  <rect width="{width}" height="{height}" rx="8" fill="{bg}"/>
  <g font-family="{FONT}" font-size="14">
{chr(10).join(rows)}
  </g>
</svg>
"""
    (outdir / f"{slug}.svg").write_text(svg, encoding="utf-8")
    return bg


def main():
    themes = Path("themes")
    outdir = Path("docs/previews")
    outdir.mkdir(parents=True, exist_ok=True)
    index = json.loads((themes / "index.json").read_text(encoding="utf-8"))
    for t in index:
        bg = render(t["slug"], t["name"], palette(themes / f"{t['slug']}.conf"), outdir)
        print("  %-26s %s" % (t["slug"] + ".svg", bg))
    print("\n%d previews written to %s/" % (len(index), outdir))


main()
