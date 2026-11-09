#!/usr/bin/env python3
"""Renders the Dysland app icon. Usage: make_icon.py OUTPUT.png [SIZE]

A dark island above a mass of fine light strings that bend up toward it.
"""
import sys

import numpy as np
from PIL import Image, ImageFilter

SIZE = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
SS = 2  # supersampling
N = SIZE * SS
U = N / 1024.0  # one design unit on the 1024 grid

# macOS icon grid: an 824 body centred on 1024, nudged up for the shadow.
BODY = 824 * U
CX, CY = N / 2, N / 2 - 6 * U

ISLAND_W, ISLAND_H = 372 * U, 104 * U
ISLAND_Y = CY - 232 * U
APEX_Y = ISLAND_Y + ISLAND_H / 2 + 34 * U  # the gap between island and mass

STOPS = [
    (0.00, (1.00, 0.86, 0.60)),
    (0.22, (1.00, 0.58, 0.24)),
    (0.50, (1.00, 0.24, 0.30)),
    (0.76, (0.72, 0.14, 0.62)),
    (1.00, (0.20, 0.20, 0.82)),
]


def ramp(t):
    t = np.clip(t, 0, 1)
    xs = [s[0] for s in STOPS]
    return np.stack([np.interp(t, xs, [s[1][i] for s in STOPS]) for i in range(3)], -1)


def squircle(x, y, half, radius=210 * U, n=2.7):
    """Rounded square with continuous corners; 1.0 on the edge, in corner units."""
    ax = np.maximum(np.abs(x) - (half - radius), 0) / radius
    ay = np.maximum(np.abs(y) - (half - radius), 0) / radius
    return (ax ** n + ay ** n) ** (1 / n)


yy, xx = np.mgrid[0:N, 0:N].astype(np.float32) + 0.5
dx, dy = xx - CX, yy - CY

# Soft-edged masks: distance-like values divided by about a pixel.
s = squircle(dx, dy, BODY / 2)
body = np.clip((1 - s) * 210 * U / (1.2 * SS) , 0, 1)

# Ink background, a little lighter at the top.
v = (dy / BODY + 0.5)[..., None]
img = np.array([0.050, 0.048, 0.075]) * (1 - v) + np.array([0.012, 0.012, 0.030]) * v

light = np.zeros((N, N, 3), np.float32)

# Strings: each rests at its own depth and rises to the apex in the middle.
COUNT = 34
columns = dx[0]  # x offset of each column


def string_curve(t):
    """Nested like contour lines: lower strings make lower, wider peaks."""
    skirt = CY + (150 + 250 * t) * U + (columns / BODY) ** 2 * 300 * U
    apex = APEX_Y + 330 * U * t ** 1.25
    width = (70 + 260 * t ** 0.9) * U
    swell = 1 / (1 + (columns / width) ** 2) ** (1.25 - 0.45 * t)
    ripple = (2 + 13 * t) * U * np.sin(columns / (64 * U) + t * 6.0) * (1 - swell)
    return skirt + ripple + (apex - skirt) * swell, swell


for i in range(COUNT):
    t = i / (COUNT - 1)
    curve, swell = string_curve(t)
    slope = np.gradient(curve, columns)
    stretch = np.sqrt(1 + slope ** 2)

    sigma = (2.0 + 1.3 * (1 - t)) * U
    dist = (yy - curve[None, :]) / stretch[None, :]
    line = np.exp(-0.5 * (dist / sigma) ** 2)

    # Hotter near the crown, dissolving before the sides of the body.
    energy = (0.30 + 0.72 * swell) * (1.25 - 0.6 * t)
    edge_fade = np.clip(1.15 - (np.abs(columns) / (BODY * 0.50)) ** 2.6, 0, 1)
    col = ramp(t * 0.9 + 0.1 * (1 - swell))
    light += (line * (energy * edge_fade)[None, :])[..., None] * col[None, :, :] * 0.95

# The filled glow under the top string, so the mass still reads at 16 px.
top, _ = string_curve(0.0)
bottom, _ = string_curve(1.0)
span = np.maximum(bottom - top, 1)[None, :]
depth = np.clip((yy - top[None, :]) / span, 0, 1)
below = np.clip((yy - bottom[None, :]) / (130 * U), 0, 1)
under = (yy > top[None, :]) * (1 - below) ** 2
col = ramp(depth * 0.95)
fall = np.exp(-(dx / (BODY * 0.46)) ** 2)[..., None]
light += under[..., None] * col * fall * 0.26

# Halo behind the island, so its dark shape stands out from the dark ground.
r2 = ((dx / (250 * U)) ** 2 + ((yy - ISLAND_Y) / (118 * U)) ** 2)
light += np.exp(-r2)[..., None] * np.array([1.0, 0.30, 0.20]) * 0.46

img = img + light
img = 1 - np.exp(-img * 1.35)  # filmic shoulder so overlaps glow and don't clip

# The island: a true stadium, near-black, with a fine lit rim on its lower edge.
ix = np.maximum(np.abs(dx) - (ISLAND_W - ISLAND_H) / 2, 0)
iy = yy - ISLAND_Y
d = np.sqrt(ix ** 2 + iy ** 2) - ISLAND_H / 2
island = np.clip(0.5 - d / (1.2 * U), 0, 1)[..., None]
rim = np.exp(-0.5 * (d / (1.6 * U)) ** 2)[..., None] * np.clip(iy / (ISLAND_H / 2) + 0.4, 0, 1)[..., None]
img = img * (1 - island) + np.array([0.008, 0.008, 0.012]) * island
img = img + rim * np.array([1.0, 0.72, 0.5]) * 0.55

# Hairline on the body edge, as on real glass.
edge = np.exp(-(((s - 1) * 210 * U + 2.5 * U) / (2.0 * U)) ** 2)[..., None]
img = img + edge * (0.10 * (1 - v) + 0.02 * v)

rgb = np.clip(img, 0, 1) ** (1 / 1.0)
alpha = body[..., None]
out = np.concatenate([rgb * alpha, alpha], -1)  # premultiplied

# Shadow under the body, as the macOS icon grid expects.
shadow = Image.fromarray((np.roll(body, int(14 * U), 0) * 255).astype(np.uint8), "L")
shadow = shadow.filter(ImageFilter.GaussianBlur(14 * U))
sh = (np.asarray(shadow, np.float32) / 255 * 0.42)[..., None]
final_a = out[..., 3:] + sh * (1 - out[..., 3:])
final_rgb = out[..., :3]
final = np.concatenate(
    [np.where(final_a > 1e-4, final_rgb / np.maximum(final_a, 1e-4), 0), final_a], -1
)

im = Image.fromarray((np.clip(final, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")
im = im.resize((SIZE, SIZE), Image.LANCZOS)
im.save(sys.argv[1])
