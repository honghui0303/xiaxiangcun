# -*- coding: utf-8 -*-
"""纯标准库 PNG 读取 / 裁切 / 放大，用途只有一个：看渲染细节。
不依赖 Pillow（这台机器装不上）。支持 8-bit RGB / RGBA、非隔行。

用法：
  python tools/png_crop.py 输入.png 输出.png x y w h [放大倍数]
"""

import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "不是 PNG"
    pos = 8
    idat = b""
    w = h = depth = ctype = 0
    while pos < len(data):
        ln, tag = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack_from(">IIBB", body, 0)
            interlace = body[12]
            assert depth == 8, "只支持 8-bit"
            assert interlace == 0, "不支持隔行"
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * ch
    rows = []
    prev = bytearray(stride)
    p = 0
    for _y in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if f == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b = prev[i]
                c = prev[i - ch] if i >= ch else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        rows.append(line)
        prev = line
    return w, h, ch, rows


def write_png(path, w, h, ch, rows):
    ctype = {3: 2, 4: 6}[ch]
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 9))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)


def crop_scale(src, dst, x, y, cw, chh, scale=1):
    w, h, ch, rows = read_png(src)
    x = max(0, min(x, w - 1))
    y = max(0, min(y, h - 1))
    cw = max(1, min(cw, w - x))
    chh = max(1, min(chh, h - y))
    out = []
    for ry in range(chh):
        line = rows[y + ry][x * ch:(x + cw) * ch]
        if scale > 1:
            big = bytearray()
            for i in range(cw):
                px = line[i * ch:(i + 1) * ch]
                big += px * scale
            for _ in range(scale):
                out.append(big)
        else:
            out.append(bytearray(line))
    write_png(dst, cw * scale, chh * scale, ch, out)
    return cw * scale, chh * scale


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) < 6:
        print(__doc__)
        sys.exit(1)
    sc = int(a[6]) if len(a) > 6 else 1
    nw, nh = crop_scale(a[0], a[1], int(a[2]), int(a[3]), int(a[4]), int(a[5]), sc)
    print("写出 %s (%dx%d)" % (a[1], nw, nh))
