#!/usr/bin/env python3
"""Build preview.png, the 1600x900 marketplace card, in the house style of the owner's listings
(Omapager Pro, Pear Messages, Pear Passwords): dark gradient, icon tile, two-line name (second
word in the accent colour), a monospace tagline and a dim feature line on the left, and the
window screenshot - framed, with wallpaper around it - on the right.

The text block sits HIGH on purpose: the marketplace's mini-preview tile crops the bottom 10-20%
of the card, so nothing that matters may go below ~75% of the height. The script refuses to
write a card whose text runs past that.

  make_preview.py --shot window.png --icon icon.svg|icon.png \\
      --name "Pear" --name2 "Messages" --accent "#b9d25a" \\
      --tagline "Every bubble, blue|or green, in a native|Omarchy window." \\
      --features "photos · reactions|effects · bluetooth" [--out preview.png]

`|` separates lines. Keep each tagline line to ~22 characters and use 2-3 lines; features are
2 lines of 2 keywords joined by " · ". Needs Pillow and ImageMagick (for SVG icons).
"""
import argparse
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1600, 900
WHITE = (236, 238, 234)
DIM = (150, 156, 150)
FAINT = (108, 114, 108)
FONT = "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-{}.ttf"
TEXT_LIMIT = 0.75   # nothing below this fraction of H: the tile crops it


def font(size, weight="Regular"):
    return ImageFont.truetype(FONT.format(weight), size)


def hexcolor(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def background(accent):
    # near-black, lighter toward the top left, faintly tinted toward the accent
    bg = Image.new("RGB", (W, H))
    px = bg.load()
    tint = [c / 255 for c in accent]
    for y in range(H):
        for x in range(W):
            t = x / W * 0.55 + y / H * 0.45
            base = 30 - 18 * t
            px[x, y] = tuple(max(int(base * (0.82 + 0.25 * k)), 8) for k in tint)
    return bg


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius, fill=255)
    out = Image.new("RGBA", img.size)
    out.paste(img, (0, 0), mask)
    return out


def load_icon(path, size):
    if path.lower().endswith(".svg"):
        tmp = tempfile.mkdtemp()
        subprocess.run(["magick", "-background", "none", path, "-resize", f"{size}x{size}",
                        f"{tmp}/icon.png"], check=True)
        path = f"{tmp}/icon.png"
    icon = Image.open(path).convert("RGBA")
    icon.thumbnail((size, size), Image.LANCZOS)
    return icon


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shot", required=True, help="window screenshot, wallpaper padding included")
    ap.add_argument("--icon", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--name2", required=True)
    ap.add_argument("--accent", required=True, help="hex colour of the second name line")
    ap.add_argument("--tagline", required=True)
    ap.add_argument("--features", required=True)
    ap.add_argument("--shot-width", type=int, default=850)
    ap.add_argument("--out", default="preview.png")
    a = ap.parse_args()
    accent = hexcolor(a.accent)

    card = background(accent).convert("RGBA")

    # the window: right side, a little above centre (the bottom of the card gets cropped)
    win = Image.open(a.shot).convert("RGB")
    ww = a.shot_width
    wh = round(win.height * ww / win.width)
    if wh > H - 150:
        wh = H - 150
        ww = round(win.width * wh / win.height)
    win = rounded(win.resize((ww, wh), Image.LANCZOS), 22)
    wx, wy = W - ww - 70, max(60, min(92, (H - wh) // 2 - 40))
    shadow = Image.new("RGBA", (ww + 120, wh + 120), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([60, 70, ww + 60, wh + 70], 26, fill=(0, 0, 0, 150))
    card.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)), (wx - 60, wy - 60))
    card.alpha_composite(win, (wx, wy))
    ImageDraw.Draw(card).rounded_rectangle([wx, wy, wx + ww - 1, wy + wh - 1], 22,
                                           outline=(255, 255, 255, 46), width=2)

    # icon tile
    tile = 104
    d = ImageDraw.Draw(card)
    # a dark tile a shade above the background (Omapager Pro's bell tile). Drawn on an
    # overlay: ImageDraw on RGBA replaces pixels, so a translucent fill would come out white.
    over = Image.new("RGBA", card.size, (0, 0, 0, 0))
    ImageDraw.Draw(over).rounded_rectangle([92, 70, 92 + tile, 70 + tile], 22,
                                           fill=(255, 255, 255, 14), outline=(255, 255, 255, 22), width=1)
    card.alpha_composite(over)
    icon = load_icon(a.icon, 64)
    card.alpha_composite(icon, (92 + (tile - icon.width) // 2, 70 + (tile - icon.height) // 2))

    x = 98
    d.text((x - 4, 192), a.name, font=font(100, "Bold"), fill=WHITE)
    d.text((x - 4, 292), a.name2, font=font(100, "Bold"), fill=accent)
    y = 432
    for line in a.tagline.split("|"):
        d.text((x, y), line, font=font(36), fill=DIM)
        y += 47
    y += 14
    for line in a.features.split("|"):
        d.text((x, y), line, font=font(27), fill=FAINT)
        y += 36

    if y > H * TEXT_LIMIT:
        sys.exit(f"text ends at y={y} ({y / H:.0%}); the tile crops below {TEXT_LIMIT:.0%}. "
                 "Shorten the tagline or features.")
    card.convert("RGB").save(a.out, optimize=True)
    print(a.out, card.size, "text ends at y =", y, f"({y / H:.0%} of the height)")


if __name__ == "__main__":
    main()
