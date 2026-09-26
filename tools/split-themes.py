#!/usr/bin/env python3
"""Split upstream Code::Blocks theme packs into one standalone .conf per dark theme.

Run from repo root:  python tools/split-themes.py <pack.conf> [pack2.conf ...]
Outputs themes/<slug>.conf plus themes/index.json.

Each output stays a valid cb_share_config.exe-importable file, so the themes
work by hand even if someone never runs install.ps1.
"""
import json, re, sys, xml.etree.ElementTree as ET
from pathlib import Path

NON_THEME = {"ACTIVE_COLOUR_SET", "ACTIVE_LANG"}
DARK_MAX_LUMA = 110  # mean channel value; above this the theme is a light one

# Style NAME labels that can supply the comment colour, best first. Authors are
# inconsistent about which of these they actually fill in.
COMMENT_STYLES = (
    "Comment (normal)", "Comment line (normal)", "Comment",
    "Comment (documentation)", "Comment line (documentation)", "Comment (inactive)",
)

PRETTY = {
    "modnokai_night_shift": "Modnokai Night Shift",
    "modnokai_night_shift_v2": "Modnokai Night Shift v2",
    "modnokai_coffee": "Modnokai Coffee",
    "son_of_obsidian": "Son of Obsidian",
    "solarized_dark": "Solarized Dark",
    "espresso_libre": "Espresso Libre",
    "dark_gray": "Dark Gray",
    "kft2": "KFT2",
    "oblivion": "Oblivion",
    "sublime": "Sublime",
    "dracula": "Dracula",
    "vim": "Vim",
}

CDATA_OPEN = "\x00CDATA\x01"
CDATA_CLOSE = "\x02"


def default_style(theme):
    """Return (fore, back) of the C/C++ 'Default' style, falling back to any lexer."""
    lexers = [theme.find("cc")] + [l for l in theme if l.tag not in ("NAME", "cc")]
    for lex in lexers:
        if lex is None:
            continue
        for st in lex:
            n = st.find("NAME/str")
            if n is None or not n.text or n.text.strip() != "Default":
                continue
            f, b = st.find("FORE/colour"), st.find("BACK/colour")
            return (
                tuple(int(f.get(k)) for k in "rgb") if f is not None else None,
                tuple(int(b.get(k)) for k in "rgb") if b is not None else None,
            )
    return (None, None)


def style_fore(theme, wanted):
    """First FORE colour among the named styles, searching the C/C++ lexer."""
    lex = theme.find("cc")
    if lex is None:
        return None
    for name in wanted:
        for st in lex:
            n = st.find("NAME/str")
            if n is None or not n.text or n.text.strip() != name:
                continue
            f = st.find("FORE/colour")
            if f is not None:
                return tuple(int(f.get(k)) for k in "rgb")
    return None


def emit(theme, slug, outdir):
    root = ET.Element("CodeBlocksConfig", {"version": "1"})
    cs = ET.SubElement(ET.SubElement(root, "editor"), "colour_sets")
    act = ET.SubElement(ET.SubElement(cs, "ACTIVE_COLOUR_SET"), "str")
    act.text = slug
    cs.append(theme)

    # ElementTree drops CDATA on parse and cannot emit it. Code::Blocks writes
    # every <str> as CDATA, so re-wrap them all using sentinels that survive
    # escaping -- a theme name holding & or < has to come back out intact.
    for s in root.iter("str"):
        s.text = CDATA_OPEN + (s.text or "").strip() + CDATA_CLOSE

    ET.indent(root, space="\t")
    body = ET.tostring(root, encoding="unicode")

    def unwrap(m):
        inner = (m.group(1)
                 .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">"))
        return "<![CDATA[" + inner + "]]>"

    body = re.sub(re.escape(CDATA_OPEN) + "(.*?)" + re.escape(CDATA_CLOSE),
                  unwrap, body, flags=re.S)

    text = '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>\n' + body + "\n"
    (outdir / (slug + ".conf")).write_text(text, encoding="utf-8")


def main(packs):
    outdir = Path("themes")
    outdir.mkdir(exist_ok=True)
    index, seen, skipped = [], set(), []
    for pack in packs:
        cs = ET.parse(pack).getroot().find("editor/colour_sets")
        if cs is None:
            print("  !! %s: no colour_sets, skipped" % pack)
            continue
        for theme in list(cs):
            if theme.tag in NON_THEME or theme.tag in seen:
                continue
            fore, back = default_style(theme)
            if back is None or sum(back) / 3 > DARK_MAX_LUMA:
                continue  # light theme, not what we ship

            # Curation bar: a theme whose comments render in the plain-text
            # colour is unusable in an IDE (and previews as a flat block).
            # dark_gray in the upstream pack defines no comment colour at all.
            comment = style_fore(theme, COMMENT_STYLES)
            if comment is None or comment == fore:
                skipped.append((theme.tag, "no distinct comment colour"))
                continue

            seen.add(theme.tag)
            emit(theme, theme.tag, outdir)
            index.append({
                "slug": theme.tag,
                "name": PRETTY.get(theme.tag, theme.tag.replace("_", " ").title()),
                "background": "#%02x%02x%02x" % back,
                "foreground": "#%02x%02x%02x" % (fore or (255, 255, 255)),
            })
    index.sort(key=lambda t: t["name"].lower())
    (outdir / "index.json").write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    for t in index:
        print("  %-26s %-26s bg %s" % (t["slug"], t["name"], t["background"]))
    for slug, why in skipped:
        print("  skipped %-18s %s" % (slug, why))
    print("\n%d dark themes written to themes/" % len(index))


main(sys.argv[1:])
