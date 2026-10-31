#!/usr/bin/env python3
"""Draws the 5heures app icon from the logo's own geometry.

    python3 Tools/make_icon.py

Writes, under Resources/:
  Icon/AppIcon.icon/     layered Icon Composer document (light + dark), the source of truth for
                         Xcode's actool, which builds the Liquid Glass icon from it
  AppIcon.icns           pre-composed fallback for builds without Xcode (glass lighting drawn in)
  Icon/Preview/*.png     light, dark and the small-size ladder, to judge the design by eye

The logo is redrawn rather than traced: coordinates below are in the original 400 px artwork,
measured from the official file (arm tilted 15 degrees, three stripes, marquee lettering).
"""
import json, math, os, shutil, subprocess, sys
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")

NAVY = (6, 53, 110)
NAVY_DARK = (34, 92, 178)       # the brand blue, lifted so it reads on a dark background
ORANGE = (210, 89, 29)
ORANGE_RIM = (170, 52, 28)
YELLOW = (253, 188, 55)
WHITE = (255, 255, 255)

# MARK: geometry (logo units) ------------------------------------------------------------------

def rounded(points, radii, n=14):
    """A polygon with each corner rounded by its own radius."""
    out = []
    k = len(points)
    for i, p in enumerate(points):
        a, b, r = points[i - 1], points[(i + 1) % k], radii[i]
        if r <= 0:
            out.append(p); continue
        u = np.array(a, float) - p; u /= np.linalg.norm(u)
        v = np.array(b, float) - p; v /= np.linalg.norm(v)
        theta = math.acos(max(-1, min(1, float(u @ v))))
        d = r / math.tan(theta / 2)
        centre = np.array(p, float) + (u + v) / np.linalg.norm(u + v) * (r / math.sin(theta / 2))
        a0 = math.atan2(*(np.array(p) + u * d - centre)[::-1])
        a1 = math.atan2(*(np.array(p) + v * d - centre)[::-1])
        delta = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        for j in range(n + 1):
            t = a0 + delta * j / n
            out.append((centre[0] + r * math.cos(t), centre[1] + r * math.sin(t)))
    return out

def rect(x0, y0, x1, y1, r):
    return rounded([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], [r] * 4)

def clip_convex(subject, clipper):
    """Sutherland-Hodgman: `subject` cut down to the inside of the convex polygon `clipper`."""
    def inside(p, a, b): return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]) >= 0
    def cut(p, q, a, b):
        x1, y1, x2, y2, x3, y3, x4, y4 = *p, *q, *a, *b
        den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
        return (x1 + t * (x2 - x1), y1 + t * (y2 - y1))
    out = list(subject)
    for i in range(len(clipper)):
        a, b = clipper[i], clipper[(i + 1) % len(clipper)]
        inp, out = out, []
        for j in range(len(inp)):
            p, q = inp[j - 1], inp[j]
            if inside(q, a, b):
                if not inside(p, a, b): out.append(cut(p, q, a, b))
                out.append(q)
            elif inside(p, a, b):
                out.append(cut(p, q, a, b))
    return out

# The clapper arm: a 301 x 58 bar rising to the right at 15 degrees, hinged above the bubble.
_c, _s = math.cos(math.radians(15)), math.sin(math.radians(15))
_ul = np.array((44.0, 73.0)); _u = np.array((_c, -_s)); _v = np.array((_s, _c))
ARM = rounded([tuple(_ul), tuple(_ul + 301 * _u), tuple(_ul + 301 * _u + 58 * _v), tuple(_ul + 58 * _v)],
              [3, 9, 9, 3])
ARM_CORE = [tuple(_ul), tuple(_ul + 301 * _u), tuple(_ul + 301 * _u + 58 * _v), tuple(_ul + 58 * _v)]
# The hinge: the arm's left end runs almost straight down (x 44 to 52) into the bubble.
STEM = [(43.7, 76), (43.7, 104), (48, 121), (51, 139), (51, 170), (97.5, 170), (97.5, 100)]
BODY = rect(51, 139, 361, 338, 22)
TAIL = rounded([(119, 322), (247, 322), (119, 401.5)], [0, 0, 2.5])
SILHOUETTE = [ARM, STEM, BODY, TAIL]

_stripe = [(79, 77), (116, 67), (160, 94), (123, 103)]
STRIPES = []
for i in range(4):
    quad = [(x + 73.5 * i, y - 20 * i) for x, y in _stripe]
    STRIPES.append(clip_convex(quad, ARM_CORE) if i == 3 else quad)

DOTTED = [(x, y) for y in (186.5, 295.5) for x in np.arange(83.5, 327.5, 8.2)]
DOT_R = 1.9
TEXT_BOX = (58, 208, 356, 263)      # x0, y0, x1, y1 of "5 HEURES"
GLYPH_BOX = (43, -5, 361, 402)      # what the logo covers

# MARK: marquee lettering -----------------------------------------------------------------------

FONT = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"
THICKEN = 0.8   # logo units added to each side of a stroke: the logo's lettering is heavier than the font

def lettering(text, box, scale):
    """The text as an 'L' mask, `scale` px per logo unit, filling `box` exactly.

    Set in DIN Condensed Bold, stretched sideways to the logo's wide letters (which also thickens
    the stems) and thickened a little all round."""
    x0, y0, x1, y1 = box
    w, h = round((x1 - x0) * scale), round((y1 - y0) * scale)
    inset = round(THICKEN * scale)
    probe = ImageFont.truetype(FONT, 1000)
    hb = probe.getbbox("H")
    size = (h - 2 * inset) / (hb[3] - hb[1]) * 1000
    font = ImageFont.truetype(FONT, size)
    img = Image.new("L", (int(size * len(text)), int(size * 1.6)), 0)
    d = ImageDraw.Draw(img)
    x = 10.0
    for c in text:
        d.text((x, 40 - font.getbbox("H")[1]), c, font=font, fill=255)
        x += font.getlength(c) + size * 0.05
    img = img.crop(img.getbbox()).resize((w - 2 * inset, h - 2 * inset), Image.LANCZOS)
    full = Image.new("L", (w, h), 0)
    full.paste(img, (inset, inset))
    return full.filter(ImageFilter.MaxFilter(2 * inset + 1)) if inset else full

def bulbs(box, text="5 HEURES", spacing=7.2):
    """Bulb centres (logo units) down the middle of every stroke, one row.

    Eroding the lettering leaves a thin ridge along each stroke's centre; the deepest ridge
    pixels are taken first so the bulbs sit on the centreline, then shallower ones fill any gap."""
    unit = 4
    mask = lettering(text, box, unit)
    taken = []
    for radius in (30, 26, 22, 18, 15):
        core = np.array(mask.filter(ImageFilter.MinFilter(2 * radius + 1))) > 127
        ys, xs = np.nonzero(core)
        order = np.lexsort((ys, xs))
        for x, y in zip(xs[order], ys[order]):
            p = np.array((x, y), float)
            if not taken or np.min(np.hypot(*(np.array(taken) - p).T)) >= spacing * unit:
                taken.append(p)
    return [(box[0] + x / unit, box[1] + y / unit) for x, y in taken]

BULBS = bulbs(TEXT_BOX)
BULB_R = 3.0

# MARK: layers ---------------------------------------------------------------------------------

class Frame:
    """Maps logo units to the pixels of a square canvas whose side is `side` px."""
    def __init__(self, side, fill=0.70, dy=0.0):
        gx0, gy0, gx1, gy1 = GLYPH_BOX
        self.k = fill * side / (gy1 - gy0)
        self.ox = side / 2 - (gx0 + gx1) / 2 * self.k
        self.oy = side / 2 - (gy0 + gy1) / 2 * self.k + dy * side
        self.side = side
    def pt(self, p): return (p[0] * self.k + self.ox, p[1] * self.k + self.oy)
    def poly(self, pts): return [self.pt(p) for p in pts]

def canvas(side): return Image.new("RGBA", (side, side), (0, 0, 0, 0))

def fill_polys(img, fr, polys, color):
    d = ImageDraw.Draw(img)
    for p in polys: d.polygon(fr.poly(p), fill=color + (255,))

def layer_bubble(side, fr, color):
    img = canvas(side); fill_polys(img, fr, SILHOUETTE, color); return img

def layer_details(side, fr, detail="full"):
    img = canvas(side)
    fill_polys(img, fr, STRIPES, WHITE)
    if detail == "full":
        d = ImageDraw.Draw(img)
        for x, y in DOTTED:
            cx, cy = fr.pt((x, y)); r = DOT_R * fr.k
            d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=WHITE + (255,))
    return img

def layer_marquee(side, fr, detail="full"):
    img = canvas(side)
    if detail == "small":
        box = (150, 165, 262, 315)           # a single big "5" in the middle of the bubble
        text = "5"
        mask = lettering_one(text, box, fr.k)
        origin = fr.pt((box[0], box[1]))
    else:
        mask = lettering("5 HEURES", TEXT_BOX, fr.k)
        origin = fr.pt((TEXT_BOX[0], TEXT_BOX[1]))
    full = Image.new("L", (side, side), 0); full.paste(mask, (round(origin[0]), round(origin[1])))
    inner = full.filter(ImageFilter.MinFilter(max(3, 2 * round(1.5 * fr.k) + 1)))
    img.paste(Image.new("RGBA", (side, side), ORANGE_RIM + (255,)), (0, 0), full)
    img.paste(Image.new("RGBA", (side, side), ORANGE + (255,)), (0, 0), inner)
    if detail == "full":
        d = ImageDraw.Draw(img)
        for x, y in BULBS:
            cx, cy = fr.pt((x, y)); r = BULB_R * fr.k
            d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=YELLOW + (255,))
    return img

def lettering_one(text, box, scale):
    """One glyph scaled to fill `box` (used for the small-size mark)."""
    x0, y0, x1, y1 = box
    w, h = round((x1 - x0) * scale), round((y1 - y0) * scale)
    inset = round(1.6 * scale)
    probe = ImageFont.truetype(FONT, 1000)
    img = Image.new("L", (1400, 1400), 0)
    ImageDraw.Draw(img).text((100, 100), text, font=probe, fill=255)
    img = img.crop(img.getbbox()).resize((w - 2 * inset, h - 2 * inset), Image.LANCZOS)
    full = Image.new("L", (w, h), 0); full.paste(img, (inset, inset))
    return full.filter(ImageFilter.MaxFilter(2 * inset + 1))

# MARK: composing ------------------------------------------------------------------------------

def squircle(side, n=5.0):
    """Apple-like continuous corner: a superellipse filling the canvas."""
    y, x = np.mgrid[0:side, 0:side].astype(np.float64)
    c = (side - 1) / 2
    v = (np.abs(x - c) / (side / 2)) ** n + (np.abs(y - c) / (side / 2)) ** n
    return Image.fromarray(np.clip((1 - v) * side / 6, 0, 1).__mul__(255).astype(np.uint8))

def gradient(side, top, bottom):
    t = np.linspace(0, 1, side)[:, None, None]
    arr = np.array(top)[None, None, :] * (1 - t) + np.array(bottom)[None, None, :] * t
    return Image.fromarray(np.repeat(arr, side, 1).astype(np.uint8)).convert("RGBA")

def glow(layer, radius, color, strength):
    a = layer.getchannel("A").filter(ImageFilter.GaussianBlur(radius))
    a = a.point(lambda v: int(v * strength))
    out = Image.new("RGBA", layer.size, color + (0,)); out.putalpha(a); return out

def rim_light(layer, depth, strength=0.5):
    """Light catching the upper edge of a shape: its alpha minus itself shifted down."""
    a = layer.getchannel("A")
    shifted = ImageChops.offset(a, 0, depth)
    edge = ImageChops.subtract(a, shifted).filter(ImageFilter.GaussianBlur(depth / 3))
    edge = edge.point(lambda v: int(v * strength))
    out = Image.new("RGBA", layer.size, WHITE + (0,)); out.putalpha(edge); return out

def drop_shadow(layer, dy, blur, opacity, color=(0, 10, 40)):
    a = ImageChops.offset(layer.getchannel("A"), 0, dy).filter(ImageFilter.GaussianBlur(blur))
    a = a.point(lambda v: int(v * opacity))
    out = Image.new("RGBA", layer.size, color + (0,)); out.putalpha(a); return out

def scene(side, variant, detail="full"):
    """The icon artwork on a square of `side` px, before the squircle mask."""
    dark = variant == "dark"
    fr = Frame(side, fill=0.74, dy=-0.006)
    if dark:
        base = gradient(side, (22, 33, 66), (7, 11, 26))
    else:
        base = gradient(side, (255, 214, 96), (245, 158, 30))
    # soft light from the top left, as Liquid Glass backgrounds have
    hi = Image.new("RGBA", (side, side), (255, 255, 255, 0))
    yy, xx = np.mgrid[0:side, 0:side]
    dist = np.hypot(xx - side * 0.28, yy - side * 0.12) / (side * 0.75)
    hi.putalpha(Image.fromarray((np.clip(1 - dist, 0, 1) ** 1.6 * (60 if dark else 110)).astype(np.uint8)))
    base = Image.alpha_composite(base, hi)

    bubble = layer_bubble(side, fr, NAVY_DARK if dark else NAVY)
    details = layer_details(side, fr, detail)
    marquee = layer_marquee(side, fr, detail)

    out = base
    out = Image.alpha_composite(out, drop_shadow(bubble, round(side * 0.014), side * 0.016, 0.55))
    out = Image.alpha_composite(out, bubble)
    # glass: a lighter sheen over the top half of the bubble and a bright upper edge
    sheen = Image.new("RGBA", (side, side), (255, 255, 255, 0))
    g = np.clip(1 - (yy / side - 0.12) / 0.5, 0, 1) ** 1.5 * (46 if dark else 38)
    sheen.putalpha(Image.fromarray(g.astype(np.uint8)))
    sheen.putalpha(ImageChops.multiply(sheen.getchannel("A"), bubble.getchannel("A")))
    out = Image.alpha_composite(out, sheen)
    out = Image.alpha_composite(out, rim_light(bubble, max(2, round(side * 0.0045)), 0.55 if dark else 0.42))
    out = Image.alpha_composite(out, details)
    if dark:
        out = Image.alpha_composite(out, glow(marquee, side * 0.012, (255, 150, 40), 0.7))
    out = Image.alpha_composite(out, drop_shadow(marquee, round(side * 0.004), side * 0.004, 0.35, (60, 10, 0)))
    out = Image.alpha_composite(out, marquee)
    if detail == "full":
        # bulbs catch light
        out = Image.alpha_composite(out, glow(marquee, side * 0.003, (255, 200, 90), 0.25 if dark else 0.0))
    return out

def finish(art, variant):
    """Squircle mask, glass edge and the soft outer shadow macOS draws under an icon."""
    side = art.size[0]
    mask = squircle(side)
    art = art.copy(); art.putalpha(mask)
    inner = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(max(3, round(side * 0.006) | 1))))
    lit = Image.new("RGBA", (side, side), WHITE + (0,))
    yy = np.mgrid[0:side, 0:side][0] / side
    fade = np.clip(1 - yy / 0.55, 0, 1) ** 1.2
    lit.putalpha(Image.fromarray((np.array(inner) * fade * (0.40 if variant == "dark" else 0.60)).astype(np.uint8)))
    art = Image.alpha_composite(art, lit)
    # lower edge: a faint darker line so the shape holds against light backgrounds
    low = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    low.putalpha(Image.fromarray((np.array(inner) * (1 - fade) * 0.10).astype(np.uint8)))
    return Image.alpha_composite(art, low)

def detail_for(px):
    return "small" if px <= 32 else "medium" if px <= 64 else "full"

def icon(px, variant="light"):
    """A finished icon at `px` pixels square, with the standard 100/1024 margin and shadow."""
    ss = 3 if px >= 256 else 6
    side = round(px * 824 / 1024)
    art = finish(scene(side * ss, variant, detail_for(px)), variant).resize((side, side), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    m = (px - side) // 2
    sh = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    sh.paste(Image.new("RGBA", (side, side), (0, 0, 0, 255)), (m, m + round(px * 0.012)), art.getchannel("A"))
    a = sh.getchannel("A").filter(ImageFilter.GaussianBlur(px * 0.014)).point(lambda v: int(v * 0.30))
    sh.putalpha(a)
    out = Image.alpha_composite(out, sh)
    out.paste(art, (m, m), art)
    return out

# MARK: outputs --------------------------------------------------------------------------------

def svg_path(pts): return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"

def write_svg(path, side, fr, shapes):
    body = "\n".join(shapes)
    open(path, "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{side}" height="{side}" viewBox="0 0 {side} {side}">\n{body}\n</svg>\n')

def write_icon_document():
    doc = os.path.join(RES, "Icon", "AppIcon.icon")
    shutil.rmtree(doc, ignore_errors=True)
    os.makedirs(os.path.join(doc, "Assets"))
    side = 1024
    fr = Frame(side, fill=0.74, dy=-0.006)
    def shapes(color): return [f'<path d="{svg_path(fr.poly(p))}" fill="{color}"/>' for p in SILHOUETTE]
    hexc = lambda c: "#%02X%02X%02X" % c
    write_svg(os.path.join(doc, "Assets", "bubble.svg"), side, fr, shapes(hexc(NAVY)))
    write_svg(os.path.join(doc, "Assets", "bubble-dark.svg"), side, fr, shapes(hexc(NAVY_DARK)))
    details = [f'<path d="{svg_path(fr.poly(p))}" fill="#FFFFFF"/>' for p in STRIPES]
    details += [f'<circle cx="{fr.pt(p)[0]:.2f}" cy="{fr.pt(p)[1]:.2f}" r="{DOT_R * fr.k:.2f}" fill="#FFFFFF"/>' for p in DOTTED]
    write_svg(os.path.join(doc, "Assets", "details.svg"), side, fr, details)
    marquee = layer_marquee(side * 2, Frame(side * 2, fill=0.74, dy=-0.006))
    marquee.save(os.path.join(doc, "Assets", "marquee.png"))
    srgb = lambda c, a=1: "srgb:%.5f,%.5f,%.5f,%.5f" % (c[0] / 255, c[1] / 255, c[2] / 255, a)
    gradient_fill = lambda top, bottom: {"linear-gradient": [srgb(top), srgb(bottom)],
                                         "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}
    # Two things ictool taught us: the first group and the first layer are drawn on top (listed the
    # other way round, the bubble hid its stripes and the marquee), and a specialization list only
    # takes effect with an explicit default entry beside the dark one.
    spec = {
        "fill-specializations": [
            {"value": gradient_fill((255, 214, 96), (245, 158, 30))},
            {"appearance": "dark", "value": gradient_fill((22, 33, 66), (7, 11, 26))},
        ],
        "groups": [
            {"name": "marquee", "layers": [
                {"name": "marquee", "image-name": "marquee.png", "glass": False,
                 "position": {"scale": 0.47, "translation-in-points": [0, 0]}},
            ], "shadow": {"kind": "layer-color", "opacity": 0.4}},
            {"name": "bubble", "layers": [
                {"name": "details", "image-name": "details.svg", "glass": False},
                {"name": "bubble", "glass": True,
                 "image-name-specializations": [{"value": "bubble.svg"}, {"appearance": "dark", "value": "bubble-dark.svg"}]},
            ], "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0}},
        ],
        "supported-platforms": {"squares": "shared"},
    }
    json.dump(spec, open(os.path.join(doc, "icon.json"), "w"), indent=2)
    # The iPhone and iPad app takes the same document from its own folder (Xcode syncs iOS/App).
    ios = os.path.join(RES, "..", "iOS", "App", "AppIcon.icon")
    shutil.rmtree(ios, ignore_errors=True)
    shutil.copytree(doc, ios)

def write_icns():
    sets = os.path.join(RES, "AppIcon.iconset")
    shutil.rmtree(sets, ignore_errors=True); os.makedirs(sets)
    for base in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            px = base * factor
            icon(px, "light").save(os.path.join(sets, f"icon_{base}x{base}{'@2x' if factor == 2 else ''}.png"))
    subprocess.run(["iconutil", "-c", "icns", sets, "-o", os.path.join(RES, "AppIcon.icns")], check=True)
    shutil.rmtree(sets)

def write_previews():
    out = os.path.join(RES, "Icon", "Preview"); os.makedirs(out, exist_ok=True)
    for variant in ("light", "dark"):
        icon(1024, variant).save(os.path.join(out, f"{variant}-1024.png"))
    sizes = (16, 32, 64, 128, 256)
    ladder = Image.new("RGBA", (sum(sizes) + 40 * (len(sizes) + 1), 2 * 256 + 60), (236, 236, 240, 255))
    for row, variant in enumerate(("light", "dark")):
        x = 40
        for px in sizes:
            ladder.alpha_composite(icon(px, variant), (x, 20 + row * 276 + (256 - px)))
            x += px + 40
    ladder.save(os.path.join(out, "sizes.png"))

if __name__ == "__main__":
    what = sys.argv[1:] or ["document", "icns", "previews"]
    if "document" in what: write_icon_document()
    if "icns" in what: write_icns()
    if "previews" in what: write_previews()
