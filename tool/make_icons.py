"""Draws the app icon files from one geometry.

The mark is a folded-paper lightning bolt on a rounded tile: a light upper
fold, a darker lower fold over it, and a shadow where the two overlap. Two
drawings of it exist: the full one, and a slightly larger bolt for 32 px and
below, so it still fills the tile when small.

Writes:
  assets/icon/commands_mark.svg                                (title bar, splash, welcome)
  windows/runner/resources/app_icon.ico                         (exe, taskbar, installer)
  macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png

Run from the repository root:  python tool/make_icons.py
Needs Pillow.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent

# One look everywhere, whatever the theme: the warm dark tile, running from
# top to bottom.
DARK = {
    "tile": ("#2A1712", "#120907"), "upper": "#FF7B5C", "lower": "#C2372A", "fold": "#8C2219",
    "edge": None,
}

# In a 1024 grid. The upper fold is a triangle pointing up-right, the lower
# one a triangle pointing down-left; "fold" is where they overlap.
UPPER = ((655, 102), (246, 594), (553, 594))
LOWER = ((471, 430), (799, 430), (369, 922))
FOLD = ((471, 430), (587, 430), (553, 594), (437, 594))
CENTER = (522, 512)

FULL = {"rx": 232, "scale": 1.0}
SMALL = {"rx": 200, "scale": 1.1}
EDGE = 12  # an optional outline around the tile


def _shape(points, scale):
    cx, cy = CENTER
    return [(512 + (x - cx) * scale, 512 + (y - cy) * scale) for x, y in points]


def svg(geo, colors):
    def poly(points, fill):
        pts = " ".join(f"{x:.0f},{y:.0f}" for x, y in _shape(points, geo["scale"]))
        return f'  <polygon points="{pts}" fill="{fill}"/>\n'

    edge = ""
    if colors["edge"]:
        alpha = colors["edge"][3] / 255
        half = EDGE // 2
        edge = (
            f'  <rect x="{half}" y="{half}" width="{1024 - EDGE}" height="{1024 - EDGE}" '
            f'rx="{geo["rx"] - half}" fill="none" stroke="#000000" '
            f'stroke-opacity="{alpha:.2f}" stroke-width="{EDGE}"/>\n'
        )
    top, bottom = colors["tile"]
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n'
        '  <defs><linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/>'
        "</linearGradient></defs>\n"
        f'  <rect width="1024" height="1024" rx="{geo["rx"]}" fill="url(#tile)"/>\n'
        f"{edge}"
        f"{poly(UPPER, colors['upper'])}{poly(LOWER, colors['lower'])}{poly(FOLD, colors['fold'])}"
        "</svg>\n"
    )


def _rgb(hex_color):
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def render(size, geo, colors, inset=0.0):
    """The icon at size x size pixels. inset is the empty margin around the
    tile, as a share of the size (macOS icons leave one)."""
    k = max(4, 4096 // size)  # supersampling, then a smooth downscale
    n = size * k
    tile = n * (1 - 2 * inset)
    off = n * inset
    u = tile / 1024  # one grid unit in pixels

    def p(v):
        return off + v * u

    # The tile: a vertical gradient cut to a rounded square.
    top, bottom = _rgb(colors["tile"][0]), _rgb(colors["tile"][1])
    grad = Image.new("RGBA", (1, n))
    for y in range(n):
        t = min(max((y - off) / tile, 0.0), 1.0)
        grad.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    grad = grad.resize((n, n))
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([p(0), p(0), p(1024) - 1, p(1024) - 1], radius=geo["rx"] * u, fill=255)
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    img.paste(grad, (0, 0), mask)

    if colors["edge"]:
        edge = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle(
            [p(0), p(0), p(1024) - 1, p(1024) - 1],
            radius=geo["rx"] * u,
            outline=colors["edge"],
            width=max(round(EDGE * u), k),  # at least one pixel once scaled down
        )
        img.alpha_composite(edge)

    d = ImageDraw.Draw(img)
    for points, key in ((UPPER, "upper"), (LOWER, "lower"), (FOLD, "fold")):
        d.polygon([(p(x), p(y)) for x, y in _shape(points, geo["scale"])], fill=colors[key])
    return img.resize((size, size), Image.LANCZOS)


def geometry(size):
    return SMALL if size <= 32 else FULL


def main():
    icon_dir = ROOT / "assets" / "icon"
    (icon_dir / "commands_mark.svg").write_text(svg(SMALL, DARK), encoding="utf-8")

    # Windows: the dark icon, each size drawn on its own.
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [render(s, geometry(s), DARK) for s in sizes]
    ico = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    frames[-1].save(ico, format="ICO", sizes=[(s, s) for s in sizes], append_images=frames[:-1])

    # macOS: the dark icon with Apple's margin around the tile (100 of 1024).
    mac = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for s in (16, 32, 64, 128, 256, 512, 1024):
        render(s, geometry(s), DARK, inset=100 / 1024).save(mac / f"app_icon_{s}.png")


if __name__ == "__main__":
    main()
