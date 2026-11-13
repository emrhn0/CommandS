"""Draws the CommandS icon files from one geometry.

The mark is the Command key glyph drawn as one closed line on a rounded
tile, with its middle square filled red as a terminal cursor. Two drawings
of it exist: the full one, and a heavier one for 32 px and below, where the
thin line and the small loops would blur away.

Writes:
  assets/icon/commands_mark_light.svg, commands_mark_dark.svg  (title bar)
  windows/runner/resources/app_icon.ico                         (exe, taskbar, installer)
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png

Run from the repository root:  python tool/make_icons.py
Needs Pillow.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

LIGHT = {"tile": "#F2F0EB", "mark": "#111111", "cursor": "#E63322", "edge": (0, 0, 0, 36)}
DARK = {"tile": "#141414", "mark": "#F2F0EB", "cursor": "#E63322", "edge": None}

# In a 1024 grid centred on 512: h is half the middle square, r the loop
# radius, w the line weight, rx the tile corner.
FULL = {"h": 90, "r": 85, "w": 64, "rx": 232}
SMALL = {"h": 118, "r": 100, "w": 104, "rx": 200}
EDGE = 12  # the light tile's outline, so it does not melt into a light taskbar


def svg(geo, colors):
    c, h, r, w = 512, geo["h"], geo["r"], geo["w"]
    a, b = c + h, c - h
    arc = f"A{r} {r} 0 1 0"
    path = (
        f"M{a} {b - r} L{a} {a + r} {arc} {a + r} {a} L{b - r} {a} "
        f"{arc} {b} {a + r} L{b} {b - r} {arc} {b - r} {b} L{a + r} {b} "
        f"{arc} {a} {b - r} Z"
    )
    inner = b + w // 2
    side = 2 * h - w
    edge = ""
    if colors["edge"]:
        alpha = colors["edge"][3] / 255
        half = EDGE // 2
        edge = (
            f'\n  <rect x="{half}" y="{half}" width="{1024 - EDGE}" height="{1024 - EDGE}" '
            f'rx="{geo["rx"] - half}" fill="none" stroke="#000000" '
            f'stroke-opacity="{alpha:.2f}" stroke-width="{EDGE}"/>'
        )
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n'
        f'  <rect width="1024" height="1024" rx="{geo["rx"]}" fill="{colors["tile"]}"/>{edge}\n'
        f'  <path d="{path}" fill="none" stroke="{colors["mark"]}" stroke-width="{w}"/>\n'
        f'  <rect x="{inner}" y="{inner}" width="{side}" height="{side}" fill="{colors["cursor"]}"/>\n'
        "</svg>\n"
    )


def render(size, geo, colors, inset=0.0):
    """The icon at size x size pixels. inset is the empty margin around the
    tile, as a share of the size (macOS icons leave one)."""
    k = max(4, 4096 // size)  # supersampling, then a smooth downscale
    n = size * k
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    tile = n * (1 - 2 * inset)
    off = n * inset
    u = tile / 1024  # one grid unit in pixels

    def p(v):
        return off + v * u

    d.rounded_rectangle([p(0), p(0), p(1024) - 1, p(1024) - 1], radius=geo["rx"] * u, fill=colors["tile"])
    if colors["edge"]:
        edge = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle(
            [p(0), p(0), p(1024) - 1, p(1024) - 1],
            radius=geo["rx"] * u,
            outline=colors["edge"],
            width=max(round(EDGE * u), k),  # at least one pixel once scaled down
        )
        img.alpha_composite(edge)

    c, h, r, w = 512, geo["h"], geo["r"], geo["w"]
    a, b = c + h, c - h
    hw = w / 2
    m = colors["mark"]
    # The four straight runs, from loop to loop (drawn after the loops).
    runs = [
        [p(a - hw), p(b - r), p(a + hw), p(a + r)],
        [p(b - hw), p(b - r), p(b + hw), p(a + r)],
        [p(b - r), p(b - hw), p(a + r), p(b + hw)],
        [p(b - r), p(a - hw), p(a + r), p(a + hw)],
    ]
    # The four loops: three quarters of a circle each, open towards the
    # middle. Drawn as whole rings with the quarter facing the middle cut
    # away along the axes, so each ends flush with its straight run (an arc's
    # own ends are cut at slightly different angles and left a notch).
    ro = r + hw
    for cx, cy, sx, sy in ((a + r, a + r, -1, -1), (b - r, a + r, 1, -1), (b - r, b - r, 1, 1), (a + r, b - r, -1, 1)):
        ring = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        rd = ImageDraw.Draw(ring)
        ri = r - hw
        rd.ellipse([p(cx - ro), p(cy - ro), p(cx + ro), p(cy + ro)], fill=m)
        rd.ellipse([p(cx - ri), p(cy - ri), p(cx + ri), p(cy + ri)], fill=(0, 0, 0, 0))
        xs = sorted((p(cx), p(cx + sx * ro)))
        ys = sorted((p(cy), p(cy + sy * ro)))
        rd.rectangle([xs[0], ys[0], xs[1], ys[1]], fill=(0, 0, 0, 0))
        img.alpha_composite(ring)
    d = ImageDraw.Draw(img)
    for box in runs:
        d.rectangle(box, fill=m)
    d.rectangle([p(b + hw), p(b + hw), p(a - hw), p(a - hw)], fill=colors["cursor"])
    return img.resize((size, size), Image.LANCZOS)


def geometry(size):
    return SMALL if size <= 32 else FULL


def main():
    icon_dir = ROOT / "assets" / "icon"
    (icon_dir / "commands_mark_light.svg").write_text(svg(SMALL, LIGHT), encoding="utf-8")
    (icon_dir / "commands_mark_dark.svg").write_text(svg(SMALL, DARK), encoding="utf-8")

    # Windows: the light icon, each size drawn on its own.
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [render(s, geometry(s), LIGHT) for s in sizes]
    ico = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    frames[-1].save(ico, format="ICO", sizes=[(s, s) for s in sizes], append_images=frames[:-1])

    # macOS: the light icon with Apple's margin around the tile (100 of 1024).
    mac = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for s in (16, 32, 64, 128, 256, 512, 1024):
        render(s, geometry(s), LIGHT, inset=100 / 1024).save(mac / f"app_icon_{s}.png")


if __name__ == "__main__":
    main()
