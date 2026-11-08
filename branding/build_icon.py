"""Naldo Fitness mark: a ring (the smart ring) with a heartbeat line through it.

Draws the PNGs with Pillow (supersampled) and writes the matching SVG, so the
iPhone app icon, the web icons and the SVG all share one geometry.

    python build_icon.py            # writes into ./out
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

RED = (0xD1, 0x1F, 0x2E)
DARK_RED = (0x7E, 0x0F, 0x1C)
BG = (0x0B, 0x0B, 0x0F)
LINE = (0xF4, 0xF4, 0xF6)

N = 1024                     # design canvas
CX = CY = 512
R = 300                      # ring centre-line radius
RING_W = 84
PULSE_W = 50
GAP = 26                     # dark knock-out around the pulse where it crosses the ring
PULSE = [(120, 548), (352, 548), (414, 448), (492, 704), (588, 268), (664, 616), (708, 548), (904, 548)]

SS = 2                       # supersampling


def gradient(size):
    """Diagonal RED -> DARK_RED, top-left to bottom-right."""
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(RED, DARK_RED))
    return g


def draw_mark(size, background=True, mono=None):
    s = size * SS / N
    W = size * SS
    img = Image.new("RGBA", (W, W), (*BG, 255) if background else (0, 0, 0, 0))

    if background:  # soft red glow behind the ring
        glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        gr = (R + 120) * s
        gd.ellipse([CX * s - gr, CY * s - gr, CX * s + gr, CY * s + gr], fill=(*RED, 55))
        glow = glow.filter(ImageFilter.GaussianBlur(110 * s))
        img = Image.alpha_composite(img, glow)

    # ring = gradient masked by an annulus, with a gap cut where the pulse crosses
    mask = Image.new("L", (W, W), 0)
    md = ImageDraw.Draw(mask)
    ro, ri = (R + RING_W / 2) * s, (R - RING_W / 2) * s
    md.ellipse([CX * s - ro, CY * s - ro, CX * s + ro, CY * s + ro], fill=255)
    md.ellipse([CX * s - ri, CY * s - ri, CX * s + ri, CY * s + ri], fill=0)
    pts = [(x * s, y * s) for x, y in PULSE]
    _polyline(md, pts, (PULSE_W + 2 * GAP) * s, 0)
    ring_fill = Image.new("RGBA", (W, W), (*mono, 255)) if mono else gradient(W).convert("RGBA")
    ring = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ring.paste(ring_fill, (0, 0), mask)
    img = Image.alpha_composite(img, ring)

    d = ImageDraw.Draw(img)
    _polyline(d, pts, PULSE_W * s, (*(mono or LINE), 255))
    return img.resize((size, size), Image.LANCZOS)


def _polyline(d, pts, width, fill):
    d.line(pts, fill=fill, width=round(width), joint="curve")
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def svg(background=True):
    pts = " ".join(f"{x},{y}" for x, y in PULSE)
    bg = (f'<rect width="{N}" height="{N}" fill="#0B0B0F"/>\n'
          f'  <circle cx="{CX}" cy="{CY}" r="{R + 120}" fill="url(#glow)"/>\n') if background else ""
    knock = ""
    mask = (
        f'  <mask id="gap"><rect width="{N}" height="{N}" fill="#fff"/>'
        f'<polyline points="{pts}" fill="none" stroke="#000" stroke-width="{PULSE_W + 2 * GAP}" '
        f'stroke-linecap="round" stroke-linejoin="round"/></mask>\n')
    ring_mask = ' mask="url(#gap)"'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {N} {N}" role="img" aria-label="Naldo Fitness">
  <defs>
    <linearGradient id="ring" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#D11F2E"/><stop offset="1" stop-color="#7E0F1C"/>
    </linearGradient>
    <radialGradient id="glow"><stop offset="0" stop-color="#D11F2E" stop-opacity="0.28"/>
      <stop offset="1" stop-color="#D11F2E" stop-opacity="0"/></radialGradient>
{mask}  </defs>
  {bg}<circle cx="{CX}" cy="{CY}" r="{R}" fill="none" stroke="url(#ring)" stroke-width="{RING_W}"{ring_mask}/>
{knock}  <polyline points="{pts}" fill="none" stroke="#F4F4F6" stroke-width="{PULSE_W}" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
'''


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("out"))
    out.mkdir(parents=True, exist_ok=True)
    draw_mark(1024).convert("RGB").save(out / "AppIcon.png")                       # opaque
    draw_mark(1024, background=False).save(out / "AppIcon-dark.png")               # iOS dark: transparent
    draw_mark(1024, background=False, mono=(255, 255, 255)).convert("LA").save(out / "AppIcon-tinted.png")
    for name, size in (("icon-512.png", 512), ("icon-192.png", 192), ("apple-touch-icon.png", 180)):
        draw_mark(size).convert("RGB").save(out / name)
    draw_mark(64).save(out / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])
    draw_mark(32).convert("RGB").save(out / "favicon-32.png")
    (out / "naldo-fitness.svg").write_text(svg(True), encoding="utf-8")
    (out / "naldo-fitness-transparent.svg").write_text(svg(False), encoding="utf-8")
    print("written to", out)
