#!/usr/bin/env python3
"""Render the alternate FreeBNB app icons into the asset catalog.

Each option is drawn at 4x and downsampled, and rendered three times:
light, dark, and a grayscale "tinted" pass (iOS applies the user's tint
to the luminance of that image). Colours come from Assets.xcassets/Color.

Needs Pillow. Rewrites freebnb/Assets.xcassets/AppIcon*.appiconset for
every option below, leaving the primary AppIcon alone:

    python3 scripts/make_app_icons.py [path/to/Assets.xcassets]
"""

import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

S = 1024          # final icon edge
SS = 4            # supersample factor
C = S * SS        # working canvas edge

CATALOG = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "freebnb",
    "Assets.xcassets",
)


# ---------------------------------------------------------------- helpers

def px(v):
    """1024-space coordinate -> working-canvas coordinate."""
    return v * SS


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def gradient(c1, c2, angle=90):
    """Smooth linear gradient across the full canvas."""
    n = 96
    small = Image.new("RGB", (n, n))
    a = math.radians(angle)
    dx, dy = math.cos(a), math.sin(a)
    pix = small.load()
    lo = min(0, dx * (n - 1)) + min(0, dy * (n - 1))
    hi = max(0, dx * (n - 1)) + max(0, dy * (n - 1))
    span = (hi - lo) or 1
    for y in range(n):
        for x in range(n):
            t = ((x * dx + y * dy) - lo) / span
            pix[x, y] = tuple(
                round(c1[i] + (c2[i] - c1[i]) * t) for i in range(3)
            )
    return small.resize((C, C), Image.BICUBIC)


def layer():
    return Image.new("RGBA", (C, C), (0, 0, 0, 0))


def bezier(p0, p1, p2, p3, steps=48):
    out = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        out.append((
            u ** 3 * p0[0] + 3 * u ** 2 * t * p1[0] + 3 * u * t ** 2 * p2[0] + t ** 3 * p3[0],
            u ** 3 * p0[1] + 3 * u ** 2 * t * p1[1] + 3 * u * t ** 2 * p2[1] + t ** 3 * p3[1],
        ))
    return out


HEART = [  # normalised to a 100 x 100 box, bottom tip at (50, 92)
    ((50, 92), (18, 68), (4, 46), (4, 30)),
    ((4, 30), (4, 12), (17, 4), (29, 4)),
    ((29, 4), (39, 4), (46, 11), (50, 19)),
    ((50, 19), (54, 11), (61, 4), (71, 4)),
    ((71, 4), (83, 4), (96, 12), (96, 30)),
    ((96, 30), (96, 46), (82, 68), (50, 92)),
]


def heart_points(cx, cy, w):
    """Heart outline centred on (cx, cy) with the given width, in 1024 space."""
    h = w  # the normalised box is square
    pts = []
    for seg in HEART:
        for x, y in bezier(*seg):
            pts.append((
                px(cx + (x - 50) * w / 100),
                px(cy + (y - 48) * h / 100),
            ))
    return pts


def arc_points(cx, cy, r, a0, a1, steps=40):
    return [
        (
            cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / steps)),
            cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / steps)),
        )
        for i in range(steps + 1)
    ]


def stroke(draw, pts, width, color, closed=False):
    """Thick polyline with round joins and caps."""
    seq = list(pts) + ([pts[0]] if closed else [])
    draw.line(seq, fill=color, width=int(round(width)))
    r = width / 2
    for x, y in seq:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color)


def shadow(art, blur=26, dy=10, alpha=70):
    """Soft drop shadow taken from the artwork's own alpha."""
    sh = Image.new("RGBA", (C, C), (0, 0, 0, 0))
    mask = art.getchannel("A").point(lambda v: min(alpha, v))
    sh.putalpha(mask)
    sh = sh.filter(ImageFilter.GaussianBlur(px(blur) / 4))
    return sh.transform(
        (C, C), Image.AFFINE, (1, 0, 0, 0, 1, -px(dy)), resample=Image.BILINEAR
    )


def compose(bg, art, with_shadow=True):
    out = bg.convert("RGBA")
    if with_shadow:
        out = Image.alpha_composite(out, shadow(art))
    return Image.alpha_composite(out, art).convert("RGB")


# ------------------------------------------------------------ the options

def icon_key(p):
    """A latchkey whose bow is a heart: the key to a friend's spare room."""
    bg = gradient(rgb(p["bg1"]), rgb(p["bg2"]), 115)
    art = layer()
    d = ImageDraw.Draw(art)
    cream = rgb(p["fg"]) + (255,)

    # shaft
    d.rounded_rectangle(
        [px(478), px(400), px(546), px(806)], radius=px(30), fill=cream
    )
    # teeth, stepping down the right edge
    d.rounded_rectangle(
        [px(520), px(622), px(650), px(688)], radius=px(20), fill=cream
    )
    d.rounded_rectangle(
        [px(520), px(730), px(614), px(796)], radius=px(20), fill=cream
    )
    # heart bow, drawn over the top of the shaft
    d.polygon(heart_points(512, 330, 330), fill=rgb(p["accent"]) + (255,))
    # the hole through the bow
    d.ellipse(
        [px(512 - 58), px(330 - 58), px(512 + 58), px(330 + 58)],
        fill=(0, 0, 0, 0),
    )
    return compose(bg, art)


def icon_friends(p):
    """The brand mark: two friends under one roof, heart at the peak."""
    bg = gradient(rgb(p["bg1"]), rgb(p["bg2"]), 110)
    art = layer()
    d = ImageDraw.Draw(art)

    k = 10.4  # logo-mark units -> 1024 space

    def m(x, y):
        return (px((x - 60) * k + 512), px((y - 65) * k + 512))

    line = rgb(p["fg"]) + (255,)
    warm = rgb(p["warm"]) + (255,)
    w = 6 * k * SS

    house = [m(32, 62), m(60, 40), m(88, 62), m(88, 90)]
    house += [m(*q) for q in arc_points(82, 90, 6, 0, 90)]
    house += [m(38, 96)]
    house += [m(*q) for q in arc_points(38, 90, 6, 90, 180)]
    house += [m(32, 62)]
    stroke(d, house, w, line)

    r = 5.5 * k * SS
    for cx, col in ((49, warm), (71, line)):
        x, y = m(cx, 70)
        d.ellipse([x - r, y - r, x + r, y + r], fill=col)

    sw = 5 * k * SS
    stroke(d, [m(*q) for q in arc_points(49, 88, 8, 180, 360)], sw, warm)
    stroke(d, [m(*q) for q in arc_points(71, 88, 8, 180, 360)], sw, line)

    hx, hy = m(60, 36)
    d.polygon(
        heart_points(hx / SS, hy / SS, 20 * k), fill=rgb(p["accent"]) + (255,)
    )
    return compose(bg, art, with_shadow=False)


def icon_calendar(p):
    """A calendar page with a heart on it: the free nights friends offer."""
    bg = gradient(rgb(p["bg1"]), rgb(p["bg2"]), 110)
    art = layer()
    d = ImageDraw.Draw(art)
    card = rgb(p["fg"]) + (255,)
    band = rgb(p["accent"]) + (255,)

    # binder rings peeking above the page
    for x in (368, 656):
        d.rounded_rectangle(
            [px(x - 26), px(196), px(x + 26), px(300)], radius=px(26), fill=card
        )
    d.rounded_rectangle(
        [px(212), px(258), px(812), px(846)], radius=px(76), fill=card
    )
    d.rounded_rectangle(
        [px(212), px(258), px(812), px(452)],
        radius=px(76),
        fill=band,
        corners=(True, True, False, False),
    )
    d.polygon(heart_points(512, 650, 300), fill=rgb(p["mark"]) + (255,))
    return compose(bg, art)


def icon_flat(p):
    """The house mark restated flat, with the heart knocked out of it."""
    bg = gradient(rgb(p["bg1"]), rgb(p["bg2"]), 100)
    art = layer()
    d = ImageDraw.Draw(art)
    cream = rgb(p["fg"]) + (255,)

    d.polygon(
        [(px(512), px(232)), (px(880), px(556)), (px(144), px(556))], fill=cream
    )
    d.rounded_rectangle(
        [px(258), px(500), px(766), px(846)], radius=px(56), fill=cream
    )
    d.polygon(heart_points(512, 668, 292), fill=(0, 0, 0, 0))
    return compose(bg, art, with_shadow=False)


# ------------------------------------------------------------- the palettes

OPTIONS = {
    "AppIconKey": (icon_key, {
        "light": {"bg1": "#0F7E90", "bg2": "#08505C", "fg": "#FAF3E8", "accent": "#FF8A70"},
        "dark": {"bg1": "#0A4C57", "bg2": "#052A31", "fg": "#EFE6D8", "accent": "#D9563F"},
        "tinted": {"bg1": "#6F6F6F", "bg2": "#333333", "fg": "#FBFBFB", "accent": "#B8B8B8"},
    }),
    "AppIconFriends": (icon_friends, {
        "light": {"bg1": "#FDF8F0", "bg2": "#F1E4D0", "fg": "#0A6774", "warm": "#BE4537", "accent": "#FF7E6A"},
        "dark": {"bg1": "#1B292C", "bg2": "#0E1618", "fg": "#5CC1CD", "warm": "#FF8A70", "accent": "#FF7E6A"},
        "tinted": {"bg1": "#4E4E4E", "bg2": "#2A2A2A", "fg": "#F7F7F7", "warm": "#BEBEBE", "accent": "#DCDCDC"},
    }),
    "AppIconCalendar": (icon_calendar, {
        "light": {"bg1": "#12808F", "bg2": "#0A5A66", "fg": "#FAF3E8", "accent": "#E2604F", "mark": "#0A6774"},
        "dark": {"bg1": "#0B3B44", "bg2": "#061F24", "fg": "#EDE4D6", "accent": "#BE4537", "mark": "#0A5761"},
        "tinted": {"bg1": "#5C5C5C", "bg2": "#2E2E2E", "fg": "#F9F9F9", "accent": "#A6A6A6", "mark": "#6E6E6E"},
    }),
    "AppIconFlat": (icon_flat, {
        "light": {"bg1": "#EE6B54", "bg2": "#D24E3C", "fg": "#FAF3E8"},
        "dark": {"bg1": "#A83A2C", "bg2": "#7C2A1F", "fg": "#F0E7D9"},
        "tinted": {"bg1": "#4A4A4A", "bg2": "#303030", "fg": "#F7F7F7"},
    }),
}

CONTENTS = {
    "images": [
        {"filename": "{name}-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}],
         "filename": "{name}-1024-Dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
         "filename": "{name}-1024-Tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ],
    "info": {"author": "xcode", "version": 1},
}


def main(catalog):
    for name, (fn, palettes) in OPTIONS.items():
        folder = os.path.join(catalog, name + ".appiconset")
        os.makedirs(folder, exist_ok=True)
        for variant, suffix in (("light", ""), ("dark", "-Dark"), ("tinted", "-Tinted")):
            img = fn(palettes[variant]).resize((S, S), Image.LANCZOS)
            img.save(os.path.join(folder, f"{name}-1024{suffix}.png"))
        contents = json.loads(json.dumps(CONTENTS).replace("{name}", name))
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            json.dump(contents, f, indent=2)
            f.write("\n")
        print("wrote", folder)


if __name__ == "__main__":
    import sys
    main(sys.argv[1] if len(sys.argv) > 1 else CATALOG)
