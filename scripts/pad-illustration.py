#!/usr/bin/env python3
"""Draw the pad as an angled 3-D illustration and print the SVG.

The result is pasted into docs/index.html. It is generated rather than drawn by
hand because the perspective is real: every keycap is a box in 3-D space, put
through the same yaw/pitch/perspective transform, then painted back to front.
Nudging the camera means changing YAW or PITCH here, not editing 400 numbers.

    ./scripts/pad-illustration.py > /tmp/pad.svg

Key colours are the ones the app actually drives, from BridgeConfig in
Sources/WLKit/StatusMapper.swift — so the picture matches the hardware.
"""

import math

# ---------------------------------------------------------------- camera

YAW = math.radians(13)      # swing the pad so its left side comes forward
PITCH = math.radians(57)    # look down on it; lower shows more of the side wall
FOCAL = 22.0                # smaller = wider lens = more dramatic convergence
SCALE = 104.0

W, H = 900, 560


SEEN = []   # every projected point, so the viewBox can be fitted at the end


def project(p):
    """(x, y, z) in pad space -> (x, y) on screen, plus a depth for sorting."""
    x, y, z = p
    # yaw about the vertical axis
    xr = x * math.cos(YAW) - y * math.sin(YAW)
    yr = x * math.sin(YAW) + y * math.cos(YAW)
    # pitch: tip the whole thing away from the viewer
    ys = yr * math.cos(PITCH) - z * math.sin(PITCH)
    depth = yr * math.sin(PITCH) + z * math.cos(PITCH)
    k = FOCAL / (FOCAL + depth)
    sx, sy = W / 2 + xr * SCALE * k, H / 2 + ys * SCALE * k
    SEEN.append((sx, sy))
    return (sx, sy, depth)


def rounded_rect(cx, cy, w, h, r, z, seg=6):
    """Corner-rounded rectangle in the z-plane, as a point list."""
    hw, hh = w / 2 - r, h / 2 - r
    pts = []
    centres = [(cx + hw, cy + hh), (cx - hw, cy + hh), (cx - hw, cy - hh), (cx + hw, cy - hh)]
    for corner, (ccx, ccy) in enumerate(centres):
        a0 = corner * (math.pi / 2)
        for i in range(seg + 1):
            a = a0 + i * (math.pi / 2) / seg
            pts.append((ccx + r * math.cos(a), ccy + r * math.sin(a), z))
    return pts


def hull(points):
    """Andrew monotone chain. The silhouette of an extruded convex shape is the
    convex hull of its top and bottom rings, which saves deciding face by face
    which sides are visible."""
    pts = sorted(set((round(x, 4), round(y, 4)) for x, y in points))
    if len(pts) < 3:
        return pts

    def half(seq):
        out = []
        for p in seq:
            while len(out) >= 2:
                (ax, ay), (bx, by) = out[-2], out[-1]
                if (bx - ax) * (p[1] - ay) - (by - ay) * (p[0] - ax) <= 0:
                    out.pop()
                else:
                    break
            out.append(p)
        return out

    return half(pts)[:-1] + half(reversed(pts))[:-1]


def path(points2d, close=True):
    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in points2d)
    return d + (" Z" if close else "")


def shade(hex_colour, factor):
    """Multiply a #rrggbb toward black (factor<1) or white (factor>1)."""
    n = int(hex_colour.lstrip("#"), 16)
    out = []
    for shift in (16, 8, 0):
        c = (n >> shift) & 0xFF
        c = c * factor if factor <= 1 else c + (255 - c) * (factor - 1)
        out.append(max(0, min(255, int(round(c)))))
    return "#%02X%02X%02X" % tuple(out)


# ---------------------------------------------------------------- the pad

# Colours the app really drives (BridgeConfig).
BLOCKED, WORKING, DONE, IDLE = "#FF2D2D", "#FFA000", "#00B0FF", "#00C853"
STACK, TABS, LAND = "#7C4DFF", "#00BFA5", "#E91E63"
VOICE, MACRO = "#ECEFF1", "#90A4AE"
DARKCAP = "#23262E"

U = 1.0          # one key unit
GAP = 0.12
KEY_H = 0.24     # keycap height
CASE_H = 0.42

# rows of (centre_x, width, colour, label) laid out in pad space
COLS = 4
span = COLS * U + (COLS - 1) * GAP


def row_keys(widths, colours, y):
    """Lay out a row left to right, centred on the pad."""
    total = sum(widths) + GAP * (len(widths) - 1)
    x = -total / 2
    out = []
    for w, c in zip(widths, colours):
        out.append((x + w / 2, y, w, c))
        x += w + GAP
    return out


rows = []
y0 = -1.78
# knobs sit on their own strip at the back; keys start below
rows += row_keys([2 * U + GAP, 2 * U + GAP], [WORKING, IDLE], y0 + 0.00)
rows += row_keys([U] * 4, [BLOCKED, DONE, IDLE, IDLE], y0 + 1.20)
rows += row_keys([U] * 4, [STACK, TABS, LAND, MACRO], y0 + 2.40)
rows += row_keys([span - GAP - U, U], [VOICE, MACRO], y0 + 3.60)

CASE_W = span + 0.85
CASE_D = 5.85
CASE_Y = -0.22   # the knob strip needs more room at the back

out = []
add = out.append

add('<defs>')
add('<filter id="glow" x="-80%" y="-80%" width="260%" height="260%">'
    '<feGaussianBlur stdDeviation="13"/></filter>')
add('<filter id="softglow" x="-60%" y="-60%" width="220%" height="220%">'
    '<feGaussianBlur stdDeviation="26"/></filter>')
add('<linearGradient id="caseTop" x1="0" y1="0" x2="0.4" y2="1">'
    '<stop offset="0" stop-color="#3A3F4A"/><stop offset="1" stop-color="#20242B"/>'
    '</linearGradient>')
add('<linearGradient id="caseSide" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" stop-color="#191C22"/><stop offset="1" stop-color="#0A0C10"/>'
    '</linearGradient>')
add('<linearGradient id="plate" x1="0" y1="0" x2="0.3" y2="1">'
    '<stop offset="0" stop-color="#15181E"/><stop offset="1" stop-color="#0D1014"/>'
    '</linearGradient>')
add('</defs>')

# ---- ambient bloom under the whole thing
cx, cy, _ = project((0, 0.6, 0))
add(f'<ellipse cx="{cx:.0f}" cy="{cy:.0f}" rx="330" ry="150" fill="#3E6BFF" '
    'opacity="0.16" filter="url(#softglow)"/>')

# ---- case body (extruded rounded slab)
case_top = rounded_rect(0, CASE_Y, CASE_W, CASE_D, 0.55, 0)
case_bot = rounded_rect(0, CASE_Y, CASE_W, CASE_D, 0.55, -CASE_H)
top2 = [(p[0], p[1]) for p in map(project, case_top)]
bot2 = [(p[0], p[1]) for p in map(project, case_bot)]
add(f'<path d="{path(hull(top2 + bot2))}" fill="url(#caseSide)" '
    'stroke="#5B6270" stroke-width="1.6" stroke-opacity="0.45"/>')
add(f'<path d="{path(top2)}" fill="url(#caseTop)"/>')

# ---- recessed key plate
plate = [(p[0], p[1]) for p in map(project, rounded_rect(0, CASE_Y + 0.46, CASE_W - 0.5, CASE_D - 1.55, 0.34, 0.02))]
add(f'<path d="{path(plate)}" fill="url(#plate)"/>')

# ---- knobs at the back: the dial and the joystick
def knob(x, y, r, height, cap="#101319"):
    body = []
    ring_t = [(p[0], p[1]) for p in map(project, [
        (x + r * math.cos(t), y + r * math.sin(t), height) for t in
        [i * math.tau / 40 for i in range(40)]])]
    ring_b = [(p[0], p[1]) for p in map(project, [
        (x + r * math.cos(t), y + r * math.sin(t), 0.02) for t in
        [i * math.tau / 40 for i in range(40)]])]
    body.append(f'<path d="{path(hull(ring_t + ring_b))}" fill="#0B0D12"/>')
    body.append(f'<path d="{path(ring_t)}" fill="{cap}"/>')
    body.append(f'<path d="{path(ring_t)}" fill="none" stroke="#4A505C" stroke-width="1.4" opacity="0.7"/>')
    return "".join(body)


add(knob(-span / 2 + 0.52, y0 - 0.88, 0.42, 0.58))
add(knob(span / 2 - 0.52, y0 - 0.88, 0.30, 0.36, cap="#171B22"))

# ---- keys, painted back to front
drawn = []
for (kx, ky, kw, colour) in rows:
    top = rounded_rect(kx, ky, kw, U, 0.17, KEY_H)
    bot = rounded_rect(kx, ky, kw, U, 0.17, 0.03)
    t2 = [(p[0], p[1]) for p in map(project, top)]
    b2 = [(p[0], p[1]) for p in map(project, bot)]
    depth = project((kx, ky, KEY_H))[2]

    body = []
    # glow first, so it sits under the cap it belongs to
    body.append(f'<path d="{path(t2)}" fill="{colour}" opacity="0.5" filter="url(#glow)"/>')
    body.append(f'<path d="{path(hull(t2 + b2))}" fill="{shade(colour, 0.52)}"/>')
    body.append(f'<path d="{path(t2)}" fill="{shade(colour, 1.06)}"/>')
    # an inset, brighter core reads as light coming through a frosted cap
    inset = [(p[0], p[1]) for p in map(project, rounded_rect(kx, ky, kw - 0.2, U - 0.2, 0.12, KEY_H + 0.001))]
    body.append(f'<path d="{path(inset)}" fill="{shade(colour, 1.34)}" opacity="0.9"/>')
    body.append(f'<path d="{path(t2)}" fill="none" stroke="{shade(colour, 1.5)}" '
                'stroke-width="1.4" opacity="0.75"/>')
    drawn.append((depth, "".join(body)))

for _, svg in sorted(drawn, key=lambda d: -d[0]):
    add(svg)

add('</svg>')

# Fit the viewBox to what was actually drawn, with room for the glow bleed.
PAD = 62
xs = [p[0] for p in SEEN]
ys = [p[1] for p in SEEN]
vx, vy = min(xs) - PAD, min(ys) - PAD
vw, vh = max(xs) - min(xs) + 2 * PAD, max(ys) - min(ys) + 2 * PAD
header = (f'<svg viewBox="{vx:.0f} {vy:.0f} {vw:.0f} {vh:.0f}" '
          'xmlns="http://www.w3.org/2000/svg" role="img" class="pad3d" '
          'aria-label="A Work Louder Creator Micro 2, seen at an angle, with its '
          'keys lit in agent status colours.">')
print(header)
print("\n".join(out))
