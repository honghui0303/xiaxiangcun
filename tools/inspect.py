# -*- coding: utf-8 -*-
"""读 BMP、做像素分析、裁切放大转 PNG。验证窗口渲染用，不是游戏代码。"""

import struct
import sys
import zlib


def load_bmp(path):
    data = open(path, "rb").read()
    assert data[:2] == b"BM"
    offset = struct.unpack_from("<I", data, 10)[0]
    w, h, planes, bpp = struct.unpack_from("<iiHH", data, 18)
    top_down = h < 0
    h = abs(h)
    stride = w * 4
    rows = []
    for y in range(h):
        start = offset + y * stride
        rows.append(data[start:start + w * 4])
    return w, h, rows, bpp


def write_png(path, w, h, rows_rgb):
    raw = b"".join(b"\x00" + r for r in rows_rgb)
    comp = zlib.compress(raw, 6)

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", comp)
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main():
    src = sys.argv[1]
    w, h, rows, bpp = load_bmp(src)
    print(f"size = {w} x {h}, bpp = {bpp}")

    print("\n-- 每 12 行的平均色（从下往上最后 340 行）--")
    for y in range(max(0, h - 340), h, 12):
        row = rows[y]
        n = w
        r = sum(row[i * 4 + 2] for i in range(0, n, 7)) // len(range(0, n, 7))
        g = sum(row[i * 4 + 1] for i in range(0, n, 7)) // len(range(0, n, 7))
        b = sum(row[i * 4 + 0] for i in range(0, n, 7)) // len(range(0, n, 7))
        bar = "#" * (r // 12)
        print(f"y={y:5d}  rgb({r:3d},{g:3d},{b:3d})  {bar}")

    crop_h = min(340, h)
    out_rows = []
    y0 = h - crop_h
    for y in range(y0, h):
        row = rows[y]
        rgb = bytearray()
        for x in range(w):
            rgb += bytes((row[x * 4 + 2], row[x * 4 + 1], row[x * 4 + 0]))
        out_rows.append(bytes(rgb))
    out = src.rsplit(".", 1)[0] + "_bottom.png"
    write_png(out, w, crop_h, out_rows)
    print("\ncrop ->", out)


if __name__ == "__main__":
    main()
