#!/usr/bin/env python3
"""Переносит версии из versions.env и VERSION во все места, где они видны.

  python3 tools/sync-versions.py          обновить файлы
  python3 tools/sync-versions.py --check  только проверить (код 1, если что-то устарело)

Что обновляется:
  assets/readme/hero-{dark,light}.svg  плашки внизу обложки (текст в контурах JetBrains Mono)
  README.md                            ?v= у обложки (сброс кэша GitHub) и строка «Вживую на …»
  index.html                           строка плашек в шапке гайда
  install.sh                           INSTALLER_VERSION и «проверено на …»

Нужен fontTools: pip install fonttools
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONT = ROOT / "tools" / "fonts" / "JetBrainsMono[wght].ttf"

# Плашки обложки: геометрия и цвета как в исходной обложке.
CHIP_Y, CHIP_H, CHIP_X0, CHIP_GAP, CHIP_PAD = 254, 28, 36.0, 8, 12
FONT_SIZE, BASELINE = 12.5, 272.5
THEMES = {
    "dark":  {"bg": "#0D1116", "stroke": "#26303B", "label": "#95A1AF", "value": "#E2E7ED"},
    "light": {"bg": "#F3F5F7", "stroke": "#D8DDE4", "label": "#5A6573", "value": "#141A21"},
}
CHIPS_BEGIN, CHIPS_END = "<!-- chips:begin -->", "<!-- chips:end -->"


def load_versions():
    v = {}
    for line in (ROOT / "versions.env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, _, val = line.partition("=")
        v[k.strip()] = val.strip().strip('"')
    need = ["MODEL", "UNIFI_OS", "NETWORK", "KERNEL", "AWG_PROTOCOL", "AWG_GO", "AWG_TOOLS", "VPS", "CHECKED"]
    miss = [k for k in need if not v.get(k)]
    if miss:
        sys.exit(f"versions.env: нет {', '.join(miss)}")
    v["INSTALLER"] = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    return v


def chips(v):
    return [
        ("проверено: ", v["MODEL"]),
        ("UniFi OS: ", v["UNIFI_OS"]),
        ("Network: ", v["NETWORK"]),
        ("AmneziaWG: ", v["AWG_PROTOCOL"]),
        ("установщик: ", v["INSTALLER"]),
    ]


class Mono:
    def __init__(self):
        from fontTools.ttLib import TTFont
        from fontTools.varLib.instancer import instantiateVariableFont
        self.fonts = {w: instantiateVariableFont(TTFont(FONT), {"wght": w}) for w in (400, 600)}

    def path(self, text, x, weight):
        from fontTools.pens.svgPathPen import SVGPathPen
        from fontTools.pens.transformPen import TransformPen
        f = self.fonts[weight]
        gs, cmap = f.getGlyphSet(), f.getBestCmap()
        s = FONT_SIZE / f["head"].unitsPerEm
        pen = SVGPathPen(gs, ntos=lambda n: ("%.1f" % n).rstrip("0").rstrip("."))
        for ch in text:
            g = gs[cmap[ord(ch)]]
            g.draw(TransformPen(pen, (s, 0, 0, -s, x, BASELINE)))
            x += g.width * s
        return pen.getCommands(), x

    def advance(self, text):
        f = self.fonts[400]
        return sum(f["hmtx"][f.getBestCmap()[ord(c)]][0] for c in text) * FONT_SIZE / f["head"].unitsPerEm


def chip_svg(mono, items, theme):
    c = THEMES[theme]
    out, x = [], CHIP_X0
    for label, value in items:
        w = mono.advance(label + value) + 2 * CHIP_PAD
        out.append(f'<rect x="{x:.1f}" y="{CHIP_Y}" width="{w:.1f}" height="{CHIP_H}" rx="14" fill="{c["bg"]}" stroke="{c["stroke"]}"/>')
        d, _ = mono.path(label.rstrip(), x + CHIP_PAD, 400)
        vx = x + CHIP_PAD + mono.advance(label)
        out.append(f'<path fill="{c["label"]}" d="{d}"/>')
        d, _ = mono.path(value, vx, 600)
        out.append(f'<path fill="{c["value"]}" d="{d}"/>')
        x += w + CHIP_GAP
    if x - CHIP_GAP > 960 - CHIP_X0:
        sys.exit("плашки не помещаются в обложку: сократите значения в versions.env")
    return "\n".join(out)


def update_hero(text, block):
    if CHIPS_BEGIN in text:
        return re.sub(re.escape(CHIPS_BEGIN) + r".*?" + re.escape(CHIPS_END),
                      lambda _: f"{CHIPS_BEGIN}\n{block}\n{CHIPS_END}", text, flags=re.S)
    # Первый запуск: плашки — всё, что начинается с первого <rect … y="254"> до </svg>.
    i = text.index(f'y="{CHIP_Y}"')
    i = text.rindex("<rect", 0, i)
    j = text.rindex("</svg>")
    return text[:i] + f"{CHIPS_BEGIN}\n{block}\n{CHIPS_END}\n" + text[j:]


def sub1(text, pattern, repl, where):
    new, n = re.subn(pattern, repl, text, count=1, flags=re.M)
    if n != 1:
        sys.exit(f"{where}: не нашёл место для версии ({pattern})")
    return new


def main():
    check = "--check" in sys.argv[1:]
    v = load_versions()
    items = chips(v)
    stamp = hashlib.sha1(repr(items).encode()).hexdigest()[:8]
    changes = {}

    def put(rel, new):
        p = ROOT / rel
        if p.read_text(encoding="utf-8") != new:
            changes[rel] = new

    mono = Mono()
    for theme in THEMES:
        rel = f"assets/readme/hero-{theme}.svg"
        put(rel, update_hero((ROOT / rel).read_text(encoding="utf-8"), chip_svg(mono, items, theme)))

    tested = f'UniFi OS {v["UNIFI_OS"]}, Network {v["NETWORK"]}'
    r = (ROOT / "README.md").read_text(encoding="utf-8")
    r = re.sub(r"(assets/readme/hero-(?:dark|light)\.svg)\?v=[\w.-]+", rf"\1?v={stamp}", r)
    r = sub1(r, rf"^(- \*\*Вживую на {re.escape(v['MODEL'])}\*\* \()[^)]*(\))", rf"\g<1>{tested}\2", "README.md")
    put("README.md", r)

    specs = (f'<span>проверено: <b>{v["MODEL"]}</b></span><span>UniFi OS <b>{v["UNIFI_OS"]}</b></span>'
             f'<span>Network <b>{v["NETWORK"]}</b></span><span>ядро <b>{v["KERNEL"]}</b></span>'
             f'<span>amneziawg-go <b>{v["AWG_GO"]}</b></span><span>amneziawg-tools <b>{v["AWG_TOOLS"]}</b></span>'
             f'<span>установщик <b>{v["INSTALLER"]}</b></span><span>VPS <b>{v["VPS"]}</b></span>'
             f'<span>{v["CHECKED"].split()[0]} <b>{" ".join(v["CHECKED"].split()[1:])}</b></span>')
    h = (ROOT / "index.html").read_text(encoding="utf-8")
    h = sub1(h, r'(<div class="specs">\n\s*)<span>проверено:.*$', lambda m: m.group(1) + specs, "index.html")
    put("index.html", h)

    s = (ROOT / "install.sh").read_text(encoding="utf-8")
    s = sub1(s, r"^INSTALLER_VERSION=.*$", f"INSTALLER_VERSION={v['INSTALLER']}", "install.sh")
    s = sub1(s, r"\(проверено на [^,()]+, UniFi OS [^,()]+, Network [^()]+\)",
             f"(проверено на {v['MODEL']}, {tested})", "install.sh")
    put("install.sh", s)

    if check:
        if changes:
            print("Версии не совпадают с versions.env/VERSION в:", ", ".join(changes))
            print("Запустите: python3 tools/sync-versions.py")
            sys.exit(1)
        print("Версии везде актуальные.")
        return
    for rel, new in changes.items():
        (ROOT / rel).write_text(new, encoding="utf-8")
        print("обновлён", rel)
    if not changes:
        print("Всё уже актуально.")


if __name__ == "__main__":
    main()
