#!/usr/bin/env python3
"""Builds the four store thumbnails the A/B test is made of.

    python3 scripts/thumbnails.py

Writes, all 1920x1080:

    art/branding/thumb-a-clock-1920x1080.png       the race
    art/branding/thumb-b-before-after-1920x1080.png the transformation
    art/branding/thumb-c-eleven-wide-1920x1080.png  the power
    art/branding/thumb-d-nightmare-1920x1080.png    the scale

The design's one rule is that the lockup does not move: the same two lines at
136 points from the same origin at 72 / 64, and the same gold hook under them,
in all four. If the type shifts between variants the test measures the type and
you learn nothing about the image. So it is built once, here, and stamped onto
each frame; only the chrome below it changes.

The images under the chrome are screenshots of the running build rather than
illustrations, because every claim the chrome makes is a claim about a mechanic
that exists: grass has height, the Commercial Deck cuts eleven tiles, the
Cemetery runs at one in the morning. A drawn mower on a store page would be a
picture of the genre rather than a picture of this game.

Sources live in art/branding/shots/ and are named for the slot they fill.
Variant A uses the full-resolution render beside them, which is what the design
asks for; the other three come out of Studio and are upscaled, so re-shooting
them larger and dropping the files back in is the whole of that improvement --
nothing here needs to change for it.

The type is FredokaOne, out of the local Roblox install, for the reason
store_art.py gives: it is the font the game itself is set in.
"""

from __future__ import annotations

import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from store_art import (  # noqa: E402
    INK,
    WHITE,
    BRANDING,
    ROOT,
    draw_tracked,
    font,
    gradient,
    rounded,
    tracked_width,
)

SHOTS = BRANDING / "shots"

W, H = 1920, 1080

GOLD_TOP = (255, 217, 104)
GOLD_BOTTOM = (245, 168, 28)
GOLD_SHADOW = (169, 110, 8)
NIGHT = (11, 9, 6)
WELL_TOP = (62, 46, 32)
WELL_BOTTOM = (26, 18, 8)
WELL_DROP = (11, 9, 6)
CREAM = (255, 232, 224)
CASH_TOP = (168, 237, 140)
CASH_BOTTOM = (95, 194, 70)


# ------------------------------------------------------------------
# Drawing primitives the design's CSS needs
# ------------------------------------------------------------------


def scrim(stops: list[tuple[float, tuple[int, int, int], float]]) -> Image.Image:
    """A vertical `linear-gradient`, as stops of (position, colour, alpha)."""
    layer = Image.new("RGBA", (1, H), (0, 0, 0, 0))
    pixels = layer.load()
    for y in range(H):
        t = y / (H - 1)
        for (t0, c0, a0), (t1, c1, a1) in zip(stops, stops[1:]):
            if t <= t1 or t1 == stops[-1][0]:
                k = 0.0 if t1 == t0 else min(max((t - t0) / (t1 - t0), 0.0), 1.0)
                colour = tuple(int(round(c0[i] + (c1[i] - c0[i]) * k)) for i in range(3))
                pixels[0, y] = colour + (int(round((a0 + (a1 - a0) * k) * 255)),)
                break
    return layer.resize((W, H), Image.BILINEAR)


def ellipse_glow(
    size: tuple[int, int], colour: tuple[int, int, int], alpha: float, fade: float
) -> Image.Image:
    """`radial-gradient(ellipse, rgba(...) 0%, transparent <fade>%)`."""
    width, height = size
    layer = Image.new("RGBA", size, colour + (0,))
    mask = Image.new("L", size, 0)
    pixels = mask.load()
    cx, cy = (width - 1) / 2, (height - 1) / 2
    for y in range(height):
        dy = ((y - cy) / cy) ** 2
        for x in range(width):
            t = (((x - cx) / cx) ** 2 + dy) ** 0.5 / fade
            if t < 1.0:
                pixels[x, y] = int(round((1.0 - t) * alpha * 255))
    layer.putalpha(mask)
    return layer


def slab(
    size: tuple[int, int],
    radius: float,
    *,
    fill=None,
    grad: tuple[tuple[int, int, int], tuple[int, int, int]] | None = None,
    border: int = 0,
    border_colour=INK,
    drop: int = 0,
    drop_colour=None,
    highlight: int = 0,
    highlight_colour=(255, 255, 255),
    highlight_alpha: float = 0.55,
) -> Image.Image:
    """One of the design's boxes: a face, a hard border, a drop and a gleam.

    Returns an image `drop` pixels taller than `size`, so the caller can place
    it by its face's top-left corner and let the shadow hang below.
    """
    width, height = size
    canvas = Image.new("RGBA", (width, height + drop), (0, 0, 0, 0))

    if drop and drop_colour:
        shadow = rounded((width, height), radius, tuple(drop_colour) + (255,))
        canvas.paste(shadow, (0, drop), shadow)

    body = rounded((width, height), radius, (255, 255, 255, 255))
    if grad is not None:
        face = gradient((width, height), grad[0], grad[1])
    else:
        face = Image.new("RGBA", (width, height), tuple(fill))
    plate = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    plate.paste(face, (0, 0), body)

    if highlight:
        #[[ `inset 0 Npx 0 rgba(...)`: a bar of light along the inside of the
        #   top edge, cut to the face so its ends follow the corner radius. ]]
        gleam = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        ImageDraw.Draw(gleam).rounded_rectangle(
            (border, border, width - 1 - border, border + highlight * 3),
            radius=max(radius - border, 2),
            fill=tuple(highlight_colour) + (int(round(highlight_alpha * 255)),),
        )
        cut = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        cut.paste(gleam.crop((0, 0, width, border + highlight)), (0, 0))
        plate.alpha_composite(Image.composite(cut, Image.new("RGBA", (width, height), (0, 0, 0, 0)), body.getchannel("A")))

    if border:
        ring = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        ImageDraw.Draw(ring).rounded_rectangle(
            (border / 2, border / 2, width - 1 - border / 2, height - 1 - border / 2),
            radius=max(radius - border / 2, 1),
            outline=tuple(border_colour) + (255,),
            width=border,
        )
        plate.alpha_composite(ring)

    canvas.alpha_composite(plate, (0, 0))
    return canvas


def text_block(
    text: str,
    size: int,
    colour,
    *,
    tracking: float = 0.0,
    outline: int = 0,
    outline_colour=INK,
    drop: tuple[int, int, float] | None = None,
    drop_colour=NIGHT,
) -> Image.Image:
    """One line of type, with its outline drawn as a pass under the fill.

    Per glyph, a stroke sits on top of the letter before it wherever two round
    shoulders overlap -- and MOW MONEY has three of those.
    """
    face = font(size)
    ascent, descent = face.getmetrics()
    pad = outline + 8 + (abs(drop[1]) if drop else 0)
    width = int(round(tracked_width(text, face, tracking))) + pad * 2
    height = ascent + descent + pad * 2
    baseline = pad + ascent

    ink_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    if outline:
        draw_tracked(
            ImageDraw.Draw(ink_layer),
            (pad, baseline),
            text,
            face,
            tuple(outline_colour) + (255,),
            tracking,
            stroke_width=outline,
            stroke_fill=tuple(outline_colour) + (255,),
        )

    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    if drop:
        dx, dy, alpha = drop
        shade = (ink_layer if outline else None)
        if shade is None:
            shade = Image.new("RGBA", (width, height), (0, 0, 0, 0))
            draw_tracked(
                ImageDraw.Draw(shade),
                (pad, baseline),
                text,
                face,
                tuple(drop_colour) + (255,),
                tracking,
            )
        shade = shade.copy()
        shade.putalpha(shade.getchannel("A").point(lambda a: int(a * alpha)))
        canvas.alpha_composite(shade, (int(dx), int(dy)))
    canvas.alpha_composite(ink_layer)

    fill_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw_tracked(
        ImageDraw.Draw(fill_layer),
        (pad, baseline),
        text,
        face,
        tuple(colour) + (255,),
        tracking,
    )
    canvas.alpha_composite(fill_layer)
    canvas.info["origin"] = (pad, pad)
    return canvas


def paste_at(target: Image.Image, block: Image.Image, x: int, y: int) -> None:
    """Places a `text_block` by the top-left of its type rather than its pad."""
    ox, oy = block.info.get("origin", (0, 0))
    target.alpha_composite(block, (int(x - ox), int(y - oy)))


def capsule(
    text: str,
    size: int,
    tracking: float,
    padding: tuple[int, int, int, int],
    border: int,
    ink,
    **slab_kwargs,
) -> Image.Image:
    """Text in a box, sized to it the way the CSS padding box is."""
    top, right, bottom, left = padding
    face = font(size)
    ascent, _ = face.getmetrics()
    width = int(round(border * 2 + left + right + tracked_width(text, face, tracking)))
    height = border * 2 + top + size + bottom
    radius = slab_kwargs.pop("radius", height / 2)
    box = slab((width, height), radius, border=border, **slab_kwargs)
    draw_tracked(
        ImageDraw.Draw(box),
        (border + left, border + top + ascent),
        text,
        face,
        tuple(ink) + (255,),
        tracking,
    )
    return box


# ------------------------------------------------------------------
# Sources
# ------------------------------------------------------------------


def fit(path: pathlib.Path, size: tuple[int, int], focus: float = 0.5) -> Image.Image:
    """The largest crop of `path` at `size`'s aspect, scaled up to it.

    `focus` is where the crop sits along whichever axis is being trimmed, 0
    being top or left. Studio's viewport is 4:3 and none of these frames is,
    so every one of them is cropped before it is scaled.
    """
    source = Image.open(path).convert("RGB")
    want = size[0] / size[1]
    have = source.width / source.height
    if have > want:
        crop_w = int(round(source.height * want))
        left = int(round((source.width - crop_w) * focus))
        source = source.crop((left, 0, left + crop_w, source.height))
    else:
        crop_h = int(round(source.width / want))
        top = int(round((source.height - crop_h) * focus))
        source = source.crop((0, top, source.width, top + crop_h))
    scaled = source.resize(size, Image.LANCZOS)
    if scaled.width > source.width:
        #[[ Upscaling a screenshot softens every edge in it, and this build is
        #   all hard edges. A light unsharp pass puts the flat-shaded borders
        #   back without touching the sky. ]]
        scaled = scaled.filter(ImageFilter.UnsharpMask(radius=2, percent=90, threshold=3))
    return scaled.convert("RGBA")


# ------------------------------------------------------------------
# The lockup, which is the same in all four
# ------------------------------------------------------------------

TITLE = 136
LEADING = TITLE * 0.92
TITLE_TRACK = -0.01 * TITLE
LOCKUP_X, LOCKUP_Y = 72, 64


def lockup(frame: Image.Image) -> None:
    face = font(TITLE)
    ascent, descent = face.getmetrics()
    #[[ CSS puts a line's box at `line-height` and centres the glyphs in it,
    #   so the first baseline sits half a leading below the block's top. ]]
    half_leading = (LEADING - (ascent + descent)) / 2

    for index, line in enumerate(("MOW MONEY,", "MOW PROBLEMS!")):
        block = text_block(
            line,
            TITLE,
            WHITE,
            tracking=TITLE_TRACK,
            outline=6,
            drop=(0, 16, 0.5),
        )
        paste_at(
            frame,
            block,
            LOCKUP_X,
            int(round(LOCKUP_Y + half_leading + index * LEADING)),
        )

    hook = capsule(
        "BEAT THE CLOCK",
        44,
        0.06 * 44,
        (14, 34, 17, 34),
        6,
        INK,
        grad=(GOLD_TOP, GOLD_BOTTOM),
        drop=8,
        drop_colour=GOLD_SHADOW,
        highlight=4,
    )
    frame.alpha_composite(hook, (LOCKUP_X, int(round(LOCKUP_Y + 2 * LEADING + 20))))


# ------------------------------------------------------------------
# A: the clock
# ------------------------------------------------------------------


def build_a() -> pathlib.Path:
    frame = fit(BRANDING / "mow-all-the-lawns-thumbnail-1920x1080.png", (W, H))
    frame.alpha_composite(
        scrim(
            [
                (0.00, NIGHT, 0.62),
                (0.34, NIGHT, 0.12),
                (0.56, NIGHT, 0.00),
                (1.00, NIGHT, 0.72),
            ]
        )
    )
    lockup(frame)

    # The clock, hard left on the bottom row.
    clock_text = "2:51:19"
    clock_face = font(74)
    dot = 26
    pad_top, pad_right, pad_bottom, pad_left = 18, 40, 22, 22
    border, gap = 6, 20
    clock_w = int(
        round(border * 2 + pad_left + pad_right + dot + gap + clock_face.getlength(clock_text))
    )
    clock_h = border * 2 + pad_top + 74 + pad_bottom
    chip = slab(
        (clock_w, clock_h),
        28,
        grad=(WELL_TOP, WELL_BOTTOM),
        border=border,
        drop=9,
        drop_colour=WELL_DROP,
        highlight=5,
        highlight_colour=(255, 206, 128),
        highlight_alpha=0.22,
    )
    live = Image.new("RGBA", (dot, dot), (0, 0, 0, 0))
    ImageDraw.Draw(live).ellipse((0, 0, dot - 1, dot - 1), fill=(126, 226, 108, 255), outline=INK + (255,), width=5)
    chip.alpha_composite(live, (border + pad_left, (clock_h - dot) // 2))
    numerals = text_block(clock_text, 74, WHITE, outline=4)
    paste_at(chip, numerals, border + pad_left + dot + gap, border + pad_top)

    bottom = H - 60
    frame.alpha_composite(chip, (72, bottom - clock_h))

    # The section and its bar, filling the rest of the row.
    bar_left = 72 + clock_w + 36
    bar_right = W - 72
    bar_w = bar_right - bar_left
    bar_h = 46

    fill_pct = 0.62
    well = slab((bar_w, bar_h), bar_h / 2, fill=(11, 9, 6, 255), border=6)
    inner = int(round(bar_w * fill_pct))
    if inner > 12:
        run = slab(
            (inner, bar_h - 12),
            (bar_h - 12) / 2,
            grad=(CASH_TOP, CASH_BOTTOM),
            highlight=6,
            highlight_alpha=0.42,
        )
        well.alpha_composite(run, (6, 6))
    frame.alpha_composite(well, (bar_left, bottom - bar_h))

    name = text_block("THE GRAND LAWN", 34, CREAM, tracking=0.04 * 34, drop=(0, 4, 0.7))
    paste_at(frame, name, bar_left, bottom - bar_h - 12 - 34)
    pct = text_block("62%", 44, WHITE, outline=3)
    pct_w = tracked_width("62%", font(44), 0)
    paste_at(frame, pct, bar_right - pct_w, bottom - bar_h - 12 - 44)

    return save(frame, "thumb-a-clock-1920x1080.png")


# ------------------------------------------------------------------
# B: before and after
# ------------------------------------------------------------------


def build_b() -> pathlib.Path:
    frame = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    frame.alpha_composite(fit(SHOTS / "b-before.png", (960, H)), (0, 0))
    frame.alpha_composite(fit(SHOTS / "b-after.png", (960, H)), (960, 0))

    # The seam, so the two halves read as one picture cut rather than two.
    ImageDraw.Draw(frame).rectangle((954, 0, 965, H), fill=INK + (255,))

    frame.alpha_composite(
        scrim(
            [
                (0.00, NIGHT, 0.58),
                (0.32, NIGHT, 0.08),
                (0.62, NIGHT, 0.00),
                (1.00, NIGHT, 0.50),
            ]
        )
    )
    lockup(frame)

    labels = [
        ("BEFORE", (238, 84, 74), (255, 138, 128), 0.25),
        ("AFTER", (79, 184, 60), (168, 237, 140), 0.75),
    ]
    for text, edge, ink, centre in labels:
        tag = capsule(
            text,
            40,
            0.12 * 40,
            (12, 44, 15, 44),
            5,
            ink,
            fill=NIGHT + (int(0.86 * 255),),
            border_colour=edge,
        )
        frame.alpha_composite(
            tag, (int(round(W * centre - tag.width / 2)), H - 56 - tag.height)
        )

    return save(frame, "thumb-b-before-after-1920x1080.png")


# ------------------------------------------------------------------
# C: eleven wide
# ------------------------------------------------------------------


def build_c() -> pathlib.Path:
    frame = fit(SHOTS / "c.png", (W, H), focus=0.42)
    frame.alpha_composite(
        scrim(
            [
                (0.00, NIGHT, 0.60),
                (0.36, NIGHT, 0.10),
                (0.70, NIGHT, 0.00),
                (1.00, NIGHT, 0.00),
            ]
        )
    )
    lockup(frame)

    #[[ Eleven bars, because the number is the claim. They are drawn rather
    #   than written out for the same reason the deck is built at eleven tiles
    #   rather than labelled: it is countable. ]]
    bars, bar_w, bar_h, bar_gap = 11, 14, 52, 6
    strip_w = bars * bar_w + (bars - 1) * bar_gap
    label = "11 WIDE"
    label_face = font(52)
    pad_top, pad_right, pad_bottom, pad_left = 16, 38, 20, 22
    border, gap = 6, 22
    chip_w = int(
        round(border * 2 + pad_left + pad_right + strip_w + gap + label_face.getlength(label))
    )
    chip_h = border * 2 + pad_top + 52 + pad_bottom
    chip = slab(
        (chip_w, chip_h),
        26,
        grad=(WELL_TOP, WELL_BOTTOM),
        border=border,
        drop=9,
        drop_colour=WELL_DROP,
        highlight=5,
        highlight_colour=(255, 206, 128),
        highlight_alpha=0.22,
    )
    x = border + pad_left
    top = (chip_h - bar_h) // 2
    for _ in range(bars):
        bar = slab((bar_w, bar_h), 4, fill=(95, 194, 70, 255), border=3)
        chip.alpha_composite(bar, (x, top))
        x += bar_w + bar_gap
    words = text_block(label, 52, WHITE, outline=3)
    paste_at(chip, words, border + pad_left + strip_w + gap, border + pad_top)

    frame.alpha_composite(chip, (W - 72 - chip_w, H - 64 - chip_h))
    return save(frame, "thumb-c-eleven-wide-1920x1080.png")


# ------------------------------------------------------------------
# D: the night property
# ------------------------------------------------------------------


def build_d() -> pathlib.Path:
    frame = fit(SHOTS / "d.png", (W, H), focus=0.06)
    frame.alpha_composite(
        scrim(
            [
                (0.00, (30, 38, 58), 0.66),
                (0.34, (30, 38, 58), 0.14),
                (0.60, NIGHT, 0.10),
                (1.00, NIGHT, 0.74),
            ]
        )
    )
    #[[ The warm patch the moon puts on the top of the frame, which is what
    #   stops a night picture reading as an underexposed day one. ]]
    frame.alpha_composite(ellipse_glow((900, 520), (255, 196, 104), 0.26, 0.68), (180, -60))

    lockup(frame)

    badges = [
        ("NIGHTMARE", 46, 0.1, (244, 234, 255), (142, 86, 200, 255), (14, 36, 18, 36)),
        ("WORLD 4 OF 4", 46, 0.04, CREAM, NIGHT + (int(0.9 * 255),), (14, 34, 18, 34)),
    ]
    x = 72
    for text, size, track, ink, fill, padding in badges:
        badge = capsule(
            text,
            size,
            track * size,
            padding,
            6,
            ink,
            radius=22,
            fill=fill,
            drop=8,
            drop_colour=WELL_DROP,
        )
        frame.alpha_composite(badge, (x, H - 64 - badge.height))
        x += badge.width + 18

    return save(frame, "thumb-d-nightmare-1920x1080.png")


def save(frame: Image.Image, name: str) -> pathlib.Path:
    out = BRANDING / name
    frame.convert("RGB").save(out)
    return out


def main() -> int:
    missing = [p for p in ("b-before.png", "b-after.png", "c.png", "d.png") if not (SHOTS / p).exists()]
    if missing:
        raise SystemExit(f"art/branding/shots/ is missing: {', '.join(missing)}")
    for path in (build_a(), build_b(), build_c(), build_d()):
        image = Image.open(path)
        print(f"{path.relative_to(ROOT)}  {image.width}x{image.height}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
