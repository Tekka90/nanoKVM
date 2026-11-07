#!/usr/bin/env python3
"""Draws the fake remote desktop (1920x1080) that the mock KVM streams. Usage: make-desktop.py out.png"""
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1920, 1080
MONO = "/System/Library/Fonts/Menlo.ttc"
SANS = "/System/Library/Fonts/Helvetica.ttc"
f = lambda path, size: ImageFont.truetype(path, size)

img = Image.new("RGB", (W, H))
px = img.load()
for y in range(H):
    for x in range(0, W):
        t = (x / W * 0.6 + y / H * 0.4)
        px[x, y] = (int(20 + 40 * t), int(24 + 50 * t), int(60 + 110 * t))
d = ImageDraw.Draw(img, "RGBA")

# top bar
d.rectangle([0, 0, W, 38], fill=(16, 18, 28, 235))
d.text((18, 9), "Activities", font=f(SANS, 18), fill=(235, 238, 245))
d.text((W / 2 - 60, 9), "Wed 28 Oct  9:41", font=f(SANS, 18), fill=(235, 238, 245))
d.text((W - 150, 9), "wifi  vol  100%", font=f(SANS, 18), fill=(235, 238, 245))

def shadow(box, radius=14):
    s = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle([box[0] + 6, box[1] + 14, box[2] + 6, box[3] + 14], radius, fill=(0, 0, 0, 120))
    img.paste(Image.alpha_composite(img.convert("RGBA"), s.filter(ImageFilter.GaussianBlur(18))).convert("RGB"))

def window(box, title, fill):
    shadow(box)
    dd = ImageDraw.Draw(img, "RGBA")
    dd.rounded_rectangle(box, 14, fill=fill)
    dd.rounded_rectangle([box[0], box[1], box[2], box[1] + 44], 14, fill=(46, 50, 64))
    dd.rectangle([box[0], box[1] + 30, box[2], box[1] + 44], fill=(46, 50, 64))
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        dd.ellipse([box[0] + 18 + i * 26, box[1] + 14, box[0] + 32 + i * 26, box[1] + 28], fill=c)
    dd.text((box[0] + (box[2] - box[0]) / 2 - 80, box[1] + 11), title, font=f(SANS, 18), fill=(220, 224, 235))
    return dd

# terminal
t = (120, 110, 1130, 800)
d = window(t, "root@homelab: ~", (22, 24, 32, 250))
lines = [
    ("root@homelab:~# ", "uptime", None),
    (None, " 09:41:07 up 42 days,  3:12,  2 users,  load average: 0.21, 0.18, 0.15", (150, 160, 175)),
    ("root@homelab:~# ", "docker ps --format '{{.Names}}  {{.Status}}'", None),
    (None, "jellyfin      Up 6 days (healthy)", (120, 220, 140)),
    (None, "home-assistant Up 6 days (healthy)", (120, 220, 140)),
    (None, "pihole        Up 6 days (healthy)", (120, 220, 140)),
    (None, "nextcloud     Up 2 days", (120, 220, 140)),
    ("root@homelab:~# ", "zpool status tank", None),
    (None, "  pool: tank", (150, 160, 175)),
    (None, " state: ONLINE", (120, 220, 140)),
    (None, "  scan: scrub repaired 0B in 03:41:20 with 0 errors", (150, 160, 175)),
    (None, "config:  mirror-0   ONLINE   0  0  0", (150, 160, 175)),
    ("root@homelab:~# ", "df -h /srv", None),
    (None, "Filesystem  Size  Used Avail Use% Mounted on", (150, 160, 175)),
    (None, "tank/srv    7.2T  4.1T  3.1T  57% /srv", (150, 160, 175)),
    ("root@homelab:~# ", "", None),
]
y = t[1] + 62
for prompt, text, color in lines:
    x = t[0] + 24
    if prompt:
        d.text((x, y), prompt, font=f(MONO, 20), fill=(110, 200, 255))
        x += d.textlength(prompt, font=f(MONO, 20))
        d.text((x, y), text, font=f(MONO, 20), fill=(240, 240, 245))
        if not text:
            d.rectangle([x, y + 2, x + 12, y + 24], fill=(240, 240, 245))
    else:
        d.text((x, y), text, font=f(MONO, 20), fill=color)
    y += 34

# system monitor
m = (1010, 300, 1800, 880)
d = window(m, "System Monitor", (30, 33, 44, 250))
d.text((m[0] + 30, m[1] + 66), "CPU", font=f(SANS, 22), fill=(220, 224, 235))
import math
pts = [(m[0] + 30 + i * 24, m[1] + 200 - (30 + 25 * math.sin(i / 2.2) + 12 * math.sin(i / 0.9)) * 1.1) for i in range(31)]
d.polygon(pts + [(pts[-1][0], m[1] + 220), (pts[0][0], m[1] + 220)], fill=(70, 150, 255, 90))
d.line(pts, fill=(90, 170, 255), width=3)
for i, (label, v, c) in enumerate([("Memory", 0.62, (120, 220, 140)), ("Swap", 0.08, (255, 200, 90)), ("Disk", 0.57, (255, 130, 120)), ("Network", 0.34, (190, 140, 255))]):
    yy = m[1] + 270 + i * 64
    d.text((m[0] + 30, yy), label, font=f(SANS, 20), fill=(200, 205, 218))
    d.rounded_rectangle([m[0] + 160, yy + 4, m[2] - 40, yy + 24], 10, fill=(55, 60, 78))
    d.rounded_rectangle([m[0] + 160, yy + 4, m[0] + 160 + (m[2] - m[0] - 200) * v, yy + 24], 10, fill=c)

# dock
dock = (W / 2 - 320, H - 96, W / 2 + 320, H - 22)
d.rounded_rectangle(dock, 24, fill=(18, 20, 30, 200))
cols = [(255, 120, 90), (90, 170, 255), (120, 220, 140), (255, 200, 90), (190, 140, 255), (90, 220, 220), (240, 240, 245)]
for i, c in enumerate(cols):
    x0 = dock[0] + 30 + i * 84
    d.rounded_rectangle([x0, dock[1] + 11, x0 + 52, dock[1] + 63], 14, fill=c)
img.save(sys.argv[1])
