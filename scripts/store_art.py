#!/usr/bin/env python3
"""Builds the two pictures the Roblox store page is made of.

The renders in art/branding/ are the art and they are not touched here. What
this adds is the part a render cannot carry: a text lockup on the thumbnail,
and a crop on the icon tight enough to survive being shown at fifty pixels.

    python3 scripts/store_art.py

Writes:
    art/branding/store-thumbnail-1920x1080.png   the render plus its lockup
    art/branding/store-icon-512.png              the render, cropped 1.6x

Both are built from the masters beside them, so re-running this after a new
render is the whole of the work. Neither is uploaded from here: Roblox has no
Open Cloud endpoint for a game's icon or its thumbnails, so those two files go
up by hand on the Creator Dashboard.

The type is FredokaOne, read out of the local Roblox install, because that is
the font the game itself is set in — the design mock asks for Fredoka 600,
which is the same face a shade lighter, and matching the game is worth more
than matching the mock.
"""

from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRANDING = ROOT / "art" / "branding"

INK = (24, 18, 10)
WHITE = (255, 255, 255)
GOLD_TOP = (255, 217, 104)
GOLD_BOTTOM = (245, 168, 28)
GOLD_SHADOW = (169, 110, 8)
TIPS = (255, 206, 74)
CASH = (126, 226, 108)


def find_font() -> pathlib.Path:
    """FredokaOne, wherever this machine's Roblox happens to keep it."""
    roots = [
        pathlib.Path.home() / ".var/app/org.vinegarhq.Vinegar/data/vinegar/versions",
        pathlib.Path.home() / ".local/share/fonts",
        pathlib.Path("/usr/share/fonts"),
    ]
    for root in roots:
        if not root.exists():
            continue
        for candidate in root.rglob("FredokaOne*.ttf"):
            return candidate
    raise SystemExit(
        "FredokaOne-Regular.ttf not found. It ships with Roblox Studio "
        "(content/fonts/), or install it into ~/.local/share/fonts."
    )


FONT_PATH = find_font()


def font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONT_PATH), size)


def tracked_width(text: str, face: ImageFont.FreeTypeFont, tracking: float) -> float:
    """CSS letter-spacing adds after every character, including the last."""
    return sum(face.getlength(ch) + tracking for ch in text)


def draw_tracked(
    draw: ImageDraw.ImageDraw,
    xy: tuple[float, float],
    text: str,
    face: ImageFont.FreeTypeFont,
    fill,
    tracking: float = 0.0,
    stroke_width: int = 0,
    stroke_fill=None,
) -> None:
    x, y = xy
    for ch in text:
        draw.text(
            (x, y),
            ch,
            font=face,
            fill=fill,
            anchor="ls",
            stroke_width=stroke_width,
            stroke_fill=stroke_fill,
        )
        x += face.getlength(ch) + tracking


def scrim(size: tuple[int, int]) -> Image.Image:
    """The soft dark corner the title sits on.

    A CSS `radial-gradient(ellipse at 8% 6%, ...)` over a box 64% by 74% of
    the frame, with the default farthest-corner sizing: the ellipse's radii
    reach the far corner of that box, and the three stops are read along it.
    """
    width, height = size
    box_w, box_h = width * 0.64, height * 0.74
    cx, cy = box_w * 0.08, box_h * 0.06
    rx, ry = box_w - cx, box_h - cy

    stops = [(0.0, 0.62), (0.42, 0.34), (0.74, 0.0)]

    layer = Image.new("RGBA", size, INK + (0,))
    alpha = Image.new("L", size, 0)
    pixels = alpha.load()
    for y in range(int(box_h) + 1):
        dy = ((y - cy) / ry) ** 2
        for x in range(int(box_w) + 1):
            t = (((x - cx) / rx) ** 2 + dy) ** 0.5
            if t >= stops[-1][0]:
                continue
            for (t0, a0), (t1, a1) in zip(stops, stops[1:]):
                if t <= t1:
                    lerp = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
                    pixels[x, y] = int(round((a0 + (a1 - a0) * lerp) * 255))
                    break
    layer.putalpha(alpha)
    return layer


def rounded(size: tuple[int, int], radius: float, fill) -> Image.Image:
    box = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(box).rounded_rectangle(
        (0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=fill
    )
    return box


def gradient(size: tuple[int, int], top, bottom) -> Image.Image:
    band = Image.new("RGB", (1, size[1]))
    pixels = band.load()
    for y in range(size[1]):
        k = y / max(size[1] - 1, 1)
        pixels[0, y] = tuple(int(round(top[i] + (bottom[i] - top[i]) * k)) for i in range(3))
    return band.resize(size, Image.NEAREST).convert("RGBA")


def pill(
    text: str,
    text_size: int,
    tracking: float,
    padding: tuple[int, int, int, int],
    border: int,
    face_top,
    face_bottom,
    ink,
    drop: int = 0,
    drop_colour=None,
    diamond: int = 0,
    highlight: int = 0,
    background=None,
    border_colour=INK,
) -> Image.Image:
    """One of the design's capsules, built the way the game builds a slab.

    A face with a gradient on it, a hard border round it, an optional solid
    drop under it and an optional bar of white inside the top edge — which is
    the thing that stops a flat capsule reading as a sticker.
    """
    top, right, bottom, left = padding
    face = font(text_size)
    content_w = tracked_width(text, face, tracking) + (diamond + 20 if diamond else 0)
    width = int(round(border * 2 + left + right + content_w))
    height = border * 2 + top + text_size + bottom
    radius = height / 2

    canvas = Image.new("RGBA", (width, height + drop), (0, 0, 0, 0))

    if drop and drop_colour:
        shadow = rounded((width, height), radius, drop_colour + (255,))
        canvas.paste(shadow, (0, drop), shadow)

    body = rounded((width, height), radius, (255, 255, 255, 255))
    if background is not None:
        fill = Image.new("RGBA", (width, height), background)
    else:
        fill = gradient((width, height), face_top, face_bottom)
    plate = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    plate.paste(fill, (0, 0), body)

    ring = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle(
        (border / 2, border / 2, width - 1 - border / 2, height - 1 - border / 2),
        radius=max(radius - border / 2, 1),
        outline=border_colour + (255,),
        width=border,
    )
    plate.alpha_composite(ring)

    if highlight:
        #[[ The bar of white just inside the top edge. Drawn as a rounded
        #   slab and then cut off at the height it is meant to be, so its
        #   ends follow the capsule rather than squaring off against it. ]]
        gleam = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        ImageDraw.Draw(gleam).rounded_rectangle(
            (border, border, width - 1 - border, border + highlight * 3),
            radius=highlight * 2,
            fill=(255, 255, 255, int(0.55 * 255)),
        )
        plate.alpha_composite(gleam.crop((0, 0, width, border + highlight)))

    draw = ImageDraw.Draw(plate)
    x = border + left
    if diamond:
        square = Image.new("RGBA", (diamond, diamond), (0, 0, 0, 0))
        ImageDraw.Draw(square).rounded_rectangle(
            (0, 0, diamond - 1, diamond - 1), radius=5, fill=ink + (255,)
        )
        turned = square.rotate(45, resample=Image.BICUBIC, expand=True)
        plate.alpha_composite(
            turned, (int(x), int((height - turned.height) / 2))
        )
        x += diamond + 20

    ascent, _ = face.getmetrics()
    draw_tracked(draw, (x, border + top + ascent), text, face, ink + (255,), tracking)

    canvas.alpha_composite(plate, (0, 0))
    return canvas


def build_thumbnail() -> pathlib.Path:
    source = BRANDING / "mow-all-the-lawns-thumbnail-1920x1080.png"
    art = Image.open(source).convert("RGBA")
    art.alpha_composite(scrim(art.size))

    title_size = 136
    line_height = title_size * 0.86
    tracking = -0.01 * title_size
    face = font(title_size)
    ascent, descent = face.getmetrics()
    half_leading = (line_height - (ascent + descent)) / 2

    lines = ["MOW MONEY,", "MOW PROBLEMS!"]
    left, top = 74, 60

    #[[ The outline is drawn as its own pass under the fill.
    #   Per glyph, a stroke would sit on top of the letter before it wherever
    #   two round shoulders overlap, and MOW MONEY has three of those. ]]
    ink_layer = Image.new("RGBA", art.size, (0, 0, 0, 0))
    ink_draw = ImageDraw.Draw(ink_layer)
    for index, line in enumerate(lines):
        baseline = top + half_leading + ascent + index * line_height
        draw_tracked(
            ink_draw,
            (left, baseline),
            line,
            face,
            INK + (255,),
            tracking,
            stroke_width=10,
            stroke_fill=INK + (255,),
        )

    # The soft drop the mock puts 22 pixels below the letters.
    shadow = ink_layer.copy()
    shadow.putalpha(shadow.getchannel("A").point(lambda a: int(a * 0.5)))
    art.alpha_composite(shadow, (0, 22))
    art.alpha_composite(ink_layer)

    white_layer = Image.new("RGBA", art.size, (0, 0, 0, 0))
    white_draw = ImageDraw.Draw(white_layer)
    for index, line in enumerate(lines):
        baseline = top + half_leading + ascent + index * line_height
        draw_tracked(white_draw, (left, baseline), line, face, WHITE + (255,), tracking)
    art.alpha_composite(white_layer)

    badge = pill(
        "BEAT THE CLOCK",
        48,
        0.02 * 48,
        (18, 38, 22, 38),
        7,
        GOLD_TOP,
        GOLD_BOTTOM,
        INK,
        drop=12,
        drop_colour=GOLD_SHADOW,
        diamond=34,
        highlight=6,
    )
    art.alpha_composite(badge, (left, int(round(top + len(lines) * line_height + 26))))

    chips = [
        ("4 PROPERTIES", TIPS),
        ("UP TO 12 PLAYERS", CASH),
    ]
    y = 56
    for text, colour in chips:
        chip = pill(
            text,
            38,
            0.06 * 38,
            (12, 28, 15, 28),
            5,
            colour,
            colour,
            colour,
            background=INK + (int(0.86 * 255),),
            border_colour=colour,
        )
        art.alpha_composite(chip, (art.width - 56 - chip.width, y))
        y += chip.height + 14

    out = BRANDING / "store-thumbnail-1920x1080.png"
    art.convert("RGB").save(out)
    return out


def build_icon() -> pathlib.Path:
    """The same render, cropped until it is a guy on a red mower.

    Two departures from the mock, both of them in service of what the mock
    says the icon is for.

    The first is the source: cropped out of the 1254 master rather than the
    512 export, so the window is 784 pixels coming down to 512 rather than
    320 going up to it. That is the softness the design's last note is about,
    and it is avoidable here.

    The second is the crop itself. The mock asks for 1.6x about 44% / 66% —
    the deck and the grille — and its own prose asks for something else three
    times over: "the mower and the player's face", "still reads as a guy on a
    red mower at every size", which is "the one thing the icon has to say".
    Those two do not both fit. A 1.6x window is 320 of the render's 512 tall,
    and the rider's head sits at about 60 while the deck runs to 470: four
    hundred and ten pixels of subject, three hundred and twenty of room. At
    44% / 66% the window opens at 127 and takes the head off.

    So: 1.45x about 35% / 30%, which holds the face, the whole red body of
    the machine and the leaf scatter along the bottom, and reads at fifty
    pixels — which is the test the design sets. Put ZOOM back to 1.6 and the
    focus to 0.44 / 0.66 for the literal crop.
    """
    master = Image.open(BRANDING / "mow-all-the-lawns-icon.png").convert("RGB")
    scale = master.width / 512

    ZOOM, FOCUS_X, FOCUS_Y = 1.45, 0.35, 0.30
    window = 512 / ZOOM
    left = FOCUS_X * (512 - window)
    top = FOCUS_Y * (512 - window)

    box = (
        int(round(left * scale)),
        int(round(top * scale)),
        int(round((left + window) * scale)),
        int(round((top + window) * scale)),
    )
    out = BRANDING / "store-icon-512.png"
    master.crop(box).resize((512, 512), Image.LANCZOS).save(out)
    return out


def main() -> int:
    for path in (build_thumbnail(), build_icon()):
        image = Image.open(path)
        print(f"{path.relative_to(ROOT)}  {image.width}x{image.height}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
