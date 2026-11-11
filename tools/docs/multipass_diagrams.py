#!/usr/bin/env python3
# docs/server-proxy.md's two diagrams, after Logan's sketches (11 Nov 2026):
# every client and server through MultiPass, and the apps' shape. Writes
# docs/images/multipass-architecture.svg and multipass-apps.svg; light and
# dark by the reader's system (prefers-color-scheme).
#
#   tools/docs/multipass_diagrams.py docs/images
import sys
out = sys.argv[1]

STYLE = """<style>
  svg { color: #1f2328; }
  @media (prefers-color-scheme: dark) { svg { color: #e6edf3; } }
  .box { fill: none; stroke: currentColor; stroke-width: 2; }
  .frame { fill: none; stroke: currentColor; stroke-width: 2.5; }
  .dash { fill: none; stroke: currentColor; stroke-width: 1.5; stroke-dasharray: 7 5; }
  .line { fill: none; stroke: currentColor; stroke-width: 1.75; }
  .head { fill: currentColor; stroke: none; }
  text { fill: currentColor; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, "DejaVu Sans", sans-serif; }
  .name { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "DejaVu Sans Mono", monospace; font-size: 16px; font-weight: 600; }
  .note { font-size: 12px; opacity: 0.7; }
  .title { font-size: 19px; font-weight: 700; }
  .label { font-size: 15px; font-weight: 600; }
  .item { font-size: 15px; }
</style>"""

MARKERS = """<defs>
  <marker id="tip" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">
    <path class="head" d="M0,0 L10,5 L0,10 z"/>
  </marker>
  <marker id="tail" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="6" markerHeight="6" orient="auto">
    <path class="head" d="M10,0 L0,5 L10,10 z"/>
  </marker>
</defs>"""

def box(x, y, w, h, name, note=None):
    s = f'<rect class="box" x="{x}" y="{y}" width="{w}" height="{h}" rx="8"/>'
    cx = x + w / 2
    if note:
        s += f'<text class="name" x="{cx}" y="{y + h/2 - 3}" text-anchor="middle">{name}</text>'
        s += f'<text class="note" x="{cx}" y="{y + h/2 + 15}" text-anchor="middle">{note}</text>'
    else:
        s += f'<text class="name" x="{cx}" y="{y + h/2 + 6}" text-anchor="middle">{name}</text>'
    return s

def arrow(x1, y1, x2, y2, both=False):
    start = ' marker-start="url(#tail)"' if both else ''
    return f'<line class="line" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"{start} marker-end="url(#tip)"/>'

def svg(w, h, body, title, top=0):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 {top} {w} {h}" width="{w}" height="{h}" role="img" aria-label="{title}">'
            f'<title>{title}</title>{STYLE}{MARKERS}{body}</svg>\n')

# 1. Every client and server through MultiPass.
b = []
# Top row: the Mac's visor_server, the primary container's, shireworks_server.
b.append(box(30, 108, 210, 64, "visor_server", "on the Mac, in Visor.app"))
b.append('<rect class="dash" x="266" y="56" width="268" height="128" rx="10"/>')
b.append('<text class="label" x="400" y="84" text-anchor="middle">Shireworks&#8217; primary container</text>')
b.append(box(310, 104, 180, 56, "visor_server"))
b.append(box(560, 108, 230, 64, "shireworks_server", "on the Mac, in Shireworks.app"))
# MultiPass.
b.append('<rect class="box" x="290" y="262" width="220" height="118" rx="8"/>')
b.append('<text class="title" x="400" y="292" text-anchor="middle">MultiPass</text>')
for i, word in enumerate(["auth", "paths", "proxy"]):
    y = 320 + i * 22
    b.append(f'<circle class="head" cx="368" cy="{y - 5}" r="3"/>')
    b.append(f'<text class="item" x="380" y="{y}">{word}</text>')
# Clients.
b.append(box(90, 462, 200, 56, "visor_client"))
b.append(box(510, 462, 220, 56, "shireworks_client"))
# Arrows: servers both ways, clients in.
b.append(arrow(150, 178, 318, 256, both=True))
b.append(arrow(400, 166, 400, 256, both=True))
b.append(arrow(660, 178, 482, 256, both=True))
b.append(arrow(200, 458, 330, 386))
b.append(arrow(610, 458, 470, 386))
open(f"{out}/multipass-architecture.svg", "w").write(svg(820, 496, "".join(b), "Every client and server through MultiPass", top=40))

# 2. The apps, in a 2 x 2 grid.
b = []
W, PAD, GAP, BW = 330, 16, 12, 298
def app(x, y, title, parts):
    s = f'<text class="label" x="{x}" y="{y}">{title}</text>'
    top = y + 12
    h = PAD * 2 + sum(p[2] for p in parts) + GAP * (len(parts) - 1)
    s += f'<rect class="frame" x="{x}" y="{top}" width="{W}" height="{h}" rx="10"/>'
    cy = top + PAD
    for name, note, ph in parts:
        s += box(x + PAD, cy, BW, ph, name, note)
        cy += ph + GAP
    return s, top + h
client = lambda n: (n, None, 48)
server = lambda n: (n, "nested, notarized", 58)
rows = [
    [("Visor.app · macOS", [client("visor_client"), server("visor_server")]),
     ("Visor · iOS / Android", [client("visor_client")])],
    [("Shireworks.app · macOS", [client("visor_client"), client("shireworks_client"), server("shireworks_server")]),
     ("Shireworks · iOS / Android", [client("visor_client"), client("shireworks_client")])],
]
y = 32
for row in rows:
    bottom = 0
    for col, (title, parts) in enumerate(row):
        s, end = app(24 + col * (W + 40), y, title, parts)
        b.append(s)
        bottom = max(bottom, end)
    y = bottom + 44
open(f"{out}/multipass-apps.svg", "w").write(svg(24 * 2 + W * 2 + 40, y - 20, "".join(b), "Visor and Shireworks, on a Mac and on a phone"))
