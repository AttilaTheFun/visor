# Crops an 8-bit, non-interlaced RGB or RGBA PNG: pngcrop.py in out x y w h
import struct, sys, zlib

def chunks(data):
    i = 8
    while i < len(data):
        n, = struct.unpack(">I", data[i:i+4]); t = data[i+4:i+8]
        yield t, data[i+8:i+8+n]; i += 12 + n

def paeth(a, b, c):
    p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)

src, dst, x, y, w, h = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:7])
data = open(src, "rb").read()
idat = b""
for t, body in chunks(data):
    if t == b"IHDR":
        W, H, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
    elif t == b"IDAT":
        idat += body
assert depth == 8 and ctype in (2, 6) and inter == 0, (depth, ctype, inter)
bpp = 3 if ctype == 2 else 4
raw = zlib.decompress(idat); stride = W * bpp
rows, prev, pos = [], bytearray(stride), 0
for r in range(H):
    f = raw[pos]; line = bytearray(raw[pos+1:pos+1+stride]); pos += 1 + stride
    for i in range(stride):
        a = line[i-bpp] if i >= bpp else 0; b = prev[i]; c = prev[i-bpp] if i >= bpp else 0
        if f == 1: line[i] = (line[i] + a) & 255
        elif f == 2: line[i] = (line[i] + b) & 255
        elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
        elif f == 4: line[i] = (line[i] + paeth(a, b, c)) & 255
    if y <= r < y + h: rows.append(b"\0" + bytes(line[x*bpp:(x+w)*bpp]))
    prev = line
def chunk(t, body):
    return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xffffffff)
out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
out += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
open(dst, "wb").write(out)
print(dst, w, h, len(out))
