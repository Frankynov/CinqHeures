#!/usr/bin/env python3
"""Draws the Apple TV app's icon and Top Shelf images from the logo in make_icon.py.

    python3 Tools/make_tv_icon.py

tvOS doesn't take Icon Composer documents: its icon is a 5:3 stack of layers that the TV moves
apart as the focus rests on it (parallax). Writes tvOS/App/Assets.xcassets/AppIcon.brandassets:
  - the icon in three layers, back to front: the yellow gradient, the navy clapper-bubble with its
    stripes and dots, the marquee lettering (400 x 240 at 1x and 2x, 1280 x 768 for the App Store);
  - the Top Shelf images (1920 x 720 and the wide 2320 x 720, at 1x and 2x): the same gradient with
    the logo, shown when the app sits in the home screen's top row.
"""
import json, os, shutil, sys
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_icon import (Frame, NAVY, drop_shadow, gradient, layer_bubble, layer_details, layer_marquee,
                       rim_light)
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "tvOS", "App", "Assets.xcassets", "AppIcon.brandassets")
INFO = {"author": "xcode", "version": 1}

TOP, BOTTOM = (255, 214, 96), (245, 158, 30)


def back(w, h):
    """The gradient, lit from the top left like the iOS icon's background."""
    img = gradient(max(w, h), TOP, BOTTOM).resize((w, h))
    yy, xx = np.mgrid[0:h, 0:w]
    dist = np.hypot(xx - w * 0.28, yy - h * 0.12) / (max(w, h) * 0.75)
    hi = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    hi.putalpha(Image.fromarray((np.clip(1 - dist, 0, 1) ** 1.6 * 110).astype(np.uint8)))
    return Image.alpha_composite(img, hi)


def logo_layers(w, h, fill, dx=0.0):
    """The bubble (with its stripes and dots) and the lettering, centred on a w x h canvas: drawn on a
    square of the canvas's height, then placed. `dx` moves the logo sideways, in parts of the width."""
    side = h
    fr = Frame(side, fill=fill, dy=-0.006)
    bubble = layer_bubble(side, fr, NAVY)
    middle = Image.alpha_composite(drop_shadow(bubble, round(side * 0.014), side * 0.016, 0.55), bubble)
    middle = Image.alpha_composite(middle, rim_light(bubble, max(2, round(side * 0.0045)), 0.42))
    middle = Image.alpha_composite(middle, layer_details(side, fr))
    marquee = layer_marquee(side, fr)
    front = Image.alpha_composite(drop_shadow(marquee, round(side * 0.004), side * 0.004, 0.35, (60, 10, 0)), marquee)
    x = round((w - side) / 2 + dx * w)
    out = []
    for layer in (middle, front):
        canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        canvas.alpha_composite(layer, (x, 0))
        out.append(canvas)
    return out


def write_contents(folder, data):
    os.makedirs(folder, exist_ok=True)
    json.dump(data, open(os.path.join(folder, "Contents.json"), "w"), indent=2)


def image_stack(name, w, h, scales):
    """An .imagestack with Front, Middle and Back layers, each an imageset at the given scales."""
    stack = os.path.join(BRAND, name + ".imagestack")
    layers = ("Front", "Middle", "Back")
    write_contents(stack, {"info": INFO, "layers": [{"filename": f"{l}.imagestacklayer"} for l in layers]})
    for scale in scales:
        pw, ph = w * scale, h * scale
        middle, front = logo_layers(pw, ph, fill=0.70)
        pictures = {"Back": back(pw, ph).convert("RGB"), "Middle": middle, "Front": front}
        for layer in layers:
            folder = os.path.join(stack, f"{layer}.imagestacklayer")
            write_contents(folder, {"info": INFO})
            content = os.path.join(folder, "Content.imageset")
            os.makedirs(content, exist_ok=True)
            pictures[layer].save(os.path.join(content, f"{layer.lower()}@{scale}x.png"))
    for layer in layers:
        content = os.path.join(stack, f"{layer}.imagestacklayer", "Content.imageset")
        write_contents(content, {"info": INFO, "images": [
            {"idiom": "tv", "scale": f"{s}x", "filename": f"{layer.lower()}@{s}x.png"} for s in scales]})


def top_shelf(name, w, h):
    folder = os.path.join(BRAND, name + ".imageset")
    os.makedirs(folder, exist_ok=True)
    images = []
    for scale in (1, 2):
        pw, ph = w * scale, h * scale
        art = back(pw, ph)
        for layer in logo_layers(pw, ph, fill=0.62):
            art = Image.alpha_composite(art, layer)
        filename = f"shelf@{scale}x.png"
        art.convert("RGB").save(os.path.join(folder, filename))
        images.append({"idiom": "tv", "scale": f"{scale}x", "filename": filename})
    write_contents(folder, {"info": INFO, "images": images})


if __name__ == "__main__":
    shutil.rmtree(BRAND, ignore_errors=True)
    write_contents(BRAND, {"info": INFO, "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ]})
    image_stack("App Icon", 400, 240, (1, 2))
    image_stack("App Icon - App Store", 1280, 768, (1,))
    top_shelf("Top Shelf Image", 1920, 720)
    top_shelf("Top Shelf Image Wide", 2320, 720)
