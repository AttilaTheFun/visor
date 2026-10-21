#!/usr/bin/env python3
"""Screenshot comparison for the snapshot tests: PNG decode/encode in the
standard library alone (no Pillow), a per-pixel diff that paints changed
pixels red over a faded copy of the reference, and an HTML report.

  pngdiff.py compare <reference.png> <capture.png> <diff.png>   -> prints changed-pixel count
  pngdiff.py report <run dir>                                   -> writes <run dir>/report.html
"""
import html, os, struct, sys, zlib

def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, width = 8, [], 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and interlace == 0, f"{path}: 8-bit, non-interlaced PNGs only"
            channels = {2: 3, 6: 4, 0: 1, 4: 2}[ctype]
        elif kind == b"IDAT":
            idat.append(body)
        pos += 12 + length
    raw = zlib.decompress(b"".join(idat))
    stride = width * channels
    rows, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    # to RGB
    out = []
    for line in rows:
        if channels == 3: out.append(bytes(line))
        elif channels == 4: out.append(bytes(b for i in range(0, len(line), 4) for b in line[i:i + 3]))
        elif channels == 1: out.append(bytes(b for v in line for b in (v, v, v)))
        else: out.append(bytes(b for i in range(0, len(line), 2) for b in (line[i],) * 3))
    return width, height, out

def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + r for r in rows)
    def chunk(kind, body): return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))

def crop_bottom(path, pixels):
    """Drops the bottom `pixels` rows (a browser's own toolbar, which is not
    the page: its tab count and load progress change run to run)."""
    width, height, rows = read_png(path)
    write_png(path, width, height - pixels, rows[:height - pixels])

def crop_top(path, pixels):
    """Drops the top `pixels` rows (a phone's status bar: its icons redraw
    between runs even in demo mode)."""
    width, height, rows = read_png(path)
    write_png(path, width, height - pixels, rows[pixels:])

def compare(ref_path, cap_path, diff_path, tolerance=16):
    """Changed pixels (any channel off by more than `tolerance`: Liquid Glass
    edges shade a few levels differently run to run); writes the
    diff image: the reference faded, changed pixels red. A size change
    counts every pixel and the diff is the capture tinted red."""
    rw, rh, ref = read_png(ref_path)
    cw, ch, cap = read_png(cap_path)
    if (rw, rh) != (cw, ch):
        write_png(diff_path, cw, ch, [bytes(255 if i % 3 == 0 else v // 3 for i, v in enumerate(r)) for r in cap])
        return cw * ch
    changed, rows = 0, []
    for y in range(rh):
        a, b = ref[y], cap[y]
        line = bytearray(len(a))
        for i in range(0, len(a), 3):
            if abs(a[i] - b[i]) > tolerance or abs(a[i + 1] - b[i + 1]) > tolerance or abs(a[i + 2] - b[i + 2]) > tolerance:
                changed += 1
                line[i:i + 3] = b"\xff\x00\x00"
            else:
                g = (a[i] + a[i + 1] + a[i + 2]) // 3
                line[i:i + 3] = bytes((200 + g // 5,) * 3)
        rows.append(bytes(line))
    write_png(diff_path, rw, rh, rows)
    return changed

def report(run_dir):
    """report.html over <run dir>/results.tsv (target, screen, status, changed, reference, capture, diff)."""
    lines = [l.rstrip("\n").split("\t") for l in open(os.path.join(run_dir, "results.tsv")) if l.strip()]
    cells = []
    for target, screen, status, changed, ref, cap, diff in lines:
        imgs = "".join(f'<figure><img src="{html.escape(p)}"><figcaption>{label}</figcaption></figure>'
                       for label, p in (("reference", ref), ("capture", cap), ("diff", diff)) if p)
        color = {"same": "#2a2", "changed": "#d22", "new": "#e90", "failed": "#d22"}.get(status, "#888")
        cells.append(f'<section><h2>{html.escape(target)} / {html.escape(screen)} '
                     f'<span style="color:{color}">{status}{" · " + changed + " px" if status == "changed" else ""}</span></h2>{imgs}</section>')
    open(os.path.join(run_dir, "report.html"), "w").write(
        "<!doctype html><meta charset=utf-8><title>Visor snapshots</title><style>body{font:14px -apple-system;background:#f6f6f6}"
        "section{background:#fff;margin:12px;padding:8px 12px;border-radius:8px}figure{display:inline-block;margin:6px}"
        "img{max-height:520px;border:1px solid #ccc}figcaption{text-align:center;color:#666}</style>" + "".join(cells))

if __name__ == "__main__":
    if sys.argv[1] == "compare":
        print(compare(sys.argv[2], sys.argv[3], sys.argv[4]))
    elif sys.argv[1] == "report":
        report(sys.argv[2])
