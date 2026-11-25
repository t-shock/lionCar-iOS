#!/usr/bin/env python3
"""Draws LionCar's app icon: a car seen from the front that is also a lion's face, framed by a scalloped mane.
Usage: make_icon.py OUT.png [variant]   (drawn at 4x and scaled down for smooth edges)"""
import math, sys
from PIL import Image, ImageDraw

OUT = sys.argv[1]
VARIANT = sys.argv[2] if len(sys.argv) > 2 else "a"
PALETTE = sys.argv[3] if len(sys.argv) > 3 else "classic"
S = 4                      # supersampling
W = 1024 * S
TEAL_TOP, TEAL_BOT = (16, 140, 132), (6, 84, 80)
GOLD, WHITE, INK = (245, 186, 66), (255, 255, 255), (8, 92, 88)
if PALETTE == "night":      # black background, teal mane, black details
    TEAL_TOP, TEAL_BOT = (34, 36, 40), (8, 9, 11)
    GOLD, INK = (0, 178, 190), (14, 15, 17)
elif PALETTE == "teal":     # teal background, black mane and details
    TEAL_TOP, TEAL_BOT = (0, 186, 199), (0, 128, 140)
    GOLD, INK = (16, 17, 20), (16, 17, 20)

def p(x): return int(round(x * S))

img = Image.new("RGB", (W, W))
d = ImageDraw.Draw(img)
for y in range(W):                      # vertical teal gradient
    t = y / (W - 1)
    d.line([(0, y), (W, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(TEAL_TOP, TEAL_BOT)))

cx, cy = 512, 530

# Mane: a disc with a ring of round scallops
n, ring, r = (14, 318, 104) if VARIANT == "a" else (12, 300, 120)
d.ellipse([p(cx - ring), p(cy - ring), p(cx + ring), p(cy + ring)], fill=GOLD)
for i in range(n):
    a = 2 * math.pi * i / n - math.pi / 2
    x, y = cx + ring * math.cos(a), cy + ring * math.sin(a)
    d.ellipse([p(x - r), p(y - r), p(x + r), p(y + r)], fill=GOLD)

def rrect(x0, y0, x1, y1, rad, fill):
    d.rounded_rectangle([p(x0), p(y0), p(x1), p(y1)], radius=p(rad), fill=fill)

def poly(pts, fill): d.polygon([(p(x), p(y)) for x, y in pts], fill=fill)

def cabin(top_y, top_hw, rad, slope_to_hw, slope_to_y, fill):
    """Roof with round top corners whose sides slope straight down into the body (no step at the shoulders)."""
    pts = []
    for x, start in ((cx - top_hw + rad, 180), (cx + top_hw - rad, 270)):
        for k in range(0, 91, 5):
            a = math.radians(start + k)
            pts.append((x + rad * math.cos(a), top_y + rad + rad * math.sin(a)))
    pts += [(cx + slope_to_hw, slope_to_y), (cx - slope_to_hw, slope_to_y)]
    poly(pts, fill)

def rounded_trapezoid(top_y, bot_y, top_hw, bot_hw, rad, fill):
    """A trapezoid with round corners: the hull of four circles."""
    cs = [(cx - top_hw + rad, top_y + rad), (cx + top_hw - rad, top_y + rad),
          (cx + bot_hw - rad, bot_y - rad), (cx - bot_hw + rad, bot_y - rad)]
    pts = []
    for (x, y), start in zip(cs, (180, 270, 0, 90)):
        for k in range(0, 91, 5):
            a = math.radians(start + k)
            pts.append((x + rad * math.cos(a), y + rad * math.sin(a)))
    poly(pts, fill)

# Car face (white): cabin, body, wheels
rrect(cx - 236, 664, cx - 150, 742, 26, INK)            # wheels peek out under the body
rrect(cx + 150, 664, cx + 236, 742, 26, INK)
cabin(322, 170, 40, 286, 600, WHITE)                     # roof
rrect(cx - 286, 470, cx + 286, 700, 64, WHITE)          # body
rounded_trapezoid(356, 470, 128, 214, 22, INK)          # windshield

# Eyes = headlights, nose = grille
def bar(x0, y0, x1, y1, w, fill):
    """A straight stroke with round ends."""
    d.line([(p(x0), p(y0)), (p(x1), p(y1))], fill=fill, width=p(w))
    for x, y in ((x0, y0), (x1, y1)):
        d.ellipse([p(x - w / 2), p(y - w / 2), p(x + w / 2), p(y + w / 2)], fill=fill)

def claws(sx, x_in, top, length, gap, w, lean):
    """Three light 'claws' in a front corner: three parallel strokes, tops leaning outwards."""
    for i in range(3):
        x = cx + sx * (x_in + i * gap)
        bar(x + sx * lean, top + i * 6, x, top + length + i * 6, w, INK)

ey = 566
for sx in (-1, 1):
    ex = cx + sx * 160
    if VARIANT == "c":                      # round eyes, claws beside them
        d.ellipse([p(ex - 44), p(ey - 44), p(ex + 44), p(ey + 44)], fill=INK)
        d.ellipse([p(ex - 15 + sx * 9), p(ey - 26), p(ex + 15 + sx * 9), p(ey + 4)], fill=WHITE)
        claws(sx, 214, 532, 84, 19, 12, 7)
    elif VARIANT == "d":                    # slim headlights, claws under them
        poly([(cx + sx * 86, 540), (cx + sx * 244, 524), (cx + sx * 252, 546), (cx + sx * 96, 562)], INK)
        claws(sx, 176, 586, 80, 28, 15, 10)
    elif VARIANT == "a":
        d.ellipse([p(ex - 48), p(ey - 48), p(ex + 48), p(ey + 48)], fill=INK)
        d.ellipse([p(ex - 16 + sx * 10), p(ey - 28), p(ex + 16 + sx * 10), p(ey + 4)], fill=WHITE)   # glint
    else:                                                                                            # plain round lamps
        d.ellipse([p(ex - 44), p(ey - 44), p(ex + 44), p(ey + 44)], fill=INK)
nose_top = 596
nose_hw = 84 if VARIANT == "d" else 46
poly([(cx - nose_hw, nose_top), (cx + nose_hw, nose_top), (cx, nose_top + 44)], INK)                           # nose / grille
if VARIANT in ("a", "c"):
    d.line([(p(cx), p(nose_top + 40)), (p(cx), p(nose_top + 62))], fill=INK, width=p(11))
    d.arc([p(cx - 46), p(nose_top + 30), p(cx), p(nose_top + 76)], 20, 160, fill=INK, width=p(11))   # smile
    d.arc([p(cx), p(nose_top + 30), p(cx + 46), p(nose_top + 76)], 20, 160, fill=INK, width=p(11))

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print(OUT)
