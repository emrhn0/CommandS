"""Draws the app icon files from one geometry.

The mark is a stack of three tabs on a rounded tile: two behind, and in
front a terminal with a prompt (>) and a red cursor. Two drawings of it
exist: the full one, and a heavier one for 32 px and below, where thin
lines would blur away.

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

# The two looks: dark (the app icon, and the title bar on dark themes) and
# light (the title bar on light themes).
DARK = {
    "tile": "#16181D", "back": "#3A3F4B", "mid": "#5B6270", "front": "#FFFFFF",
    "prompt": "#16181D", "cursor": "#E5484D", "edge": None,
}
LIGHT = {
    "tile": "#F2F0EB", "back": "#C3C7CF", "mid": "#8A919E", "front": "#16181D",
    "prompt": "#FFFFFF", "cursor": "#E5484D", "edge": (0, 0, 0, 36),
}

# In a 1024 grid. Cards are (x, y, width, height); the prompt is a chevron
# of three points; w is its line weight; rx the tile corner, crx the cards'.
FULL = {
    "rx": 232, "crx": 56,
    "back": (312, 200, 512, 398), "mid": (256, 284, 512, 398), "front": (200, 370, 512, 426),
    "prompt": ((288, 500), (370, 566), (288, 632)), "w": 40,
    "cursor": (414, 640, 136, 46),
}
SMALL = {
    "rx": 200, "crx": 64,
    "back": (330, 150, 540, 400), "mid": (240, 250, 540, 420), "front": (150, 350, 560, 520),
    "prompt": ((262, 500), (380, 600), (262, 700)), "w": 72,
    "cursor": (428, 668, 180, 72),
}
EDGE = 12  # the light tile's outline, so it does not melt into a light bar


def svg(geo, colors):
    def card(key):
        x, y, w, h = geo[key]
        return f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{geo["crx"]}" fill="{colors[key]}"/>\n'

    edge = ""
    if colors["edge"]:
        alpha = colors["edge"][3] / 255
        half = EDGE // 2
        edge = (
            f'  <rect x="{half}" y="{half}" width="{1024 - EDGE}" height="{1024 - EDGE}" '
            f'rx="{geo["rx"] - half}" fill="none" stroke="#000000" '
            f'stroke-opacity="{alpha:.2f}" stroke-width="{EDGE}"/>\n'
        )
    points = " ".join(f"{x},{y}" for x, y in geo["prompt"])
    cx, cy, cw, ch = geo["cursor"]
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n'
        f'  <rect width="1024" height="1024" rx="{geo["rx"]}" fill="{colors["tile"]}"/>\n'
        f"{edge}{card('back')}{card('mid')}{card('front')}"
        f'  <polyline points="{points}" fill="none" stroke="{colors["prompt"]}" '
        f'stroke-width="{geo["w"]}" stroke-linecap="round" stroke-linejoin="round"/>\n'
        f'  <rect x="{cx}" y="{cy}" width="{cw}" height="{ch}" fill="{colors["cursor"]}"/>\n'
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
        d = ImageDraw.Draw(img)

    for key in ("back", "mid", "front"):
        x, y, w, h = geo[key]
        d.rounded_rectangle([p(x), p(y), p(x + w), p(y + h)], radius=geo["crx"] * u, fill=colors[key])

    # The prompt: two strokes with round ends and a round corner.
    pts = [(p(x), p(y)) for x, y in geo["prompt"]]
    lw = geo["w"] * u
    d.line(pts, fill=colors["prompt"], width=round(lw), joint="curve")
    for x, y in pts:
        d.ellipse([x - lw / 2, y - lw / 2, x + lw / 2, y + lw / 2], fill=colors["prompt"])

    cx, cy, cw, ch = geo["cursor"]
    d.rectangle([p(cx), p(cy), p(cx + cw), p(cy + ch)], fill=colors["cursor"])
    return img.resize((size, size), Image.LANCZOS)


def geometry(size):
    return SMALL if size <= 32 else FULL


def main():
    icon_dir = ROOT / "assets" / "icon"
    (icon_dir / "commands_mark_light.svg").write_text(svg(SMALL, LIGHT), encoding="utf-8")
    (icon_dir / "commands_mark_dark.svg").write_text(svg(SMALL, DARK), encoding="utf-8")

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
