#!/usr/bin/env python3
"""iOS のアプリアイコンを生成する (依存なし: Python 標準ライブラリのみ)。

生成物
  ios/UchidenLink/Assets.xcassets/Contents.json
  ios/UchidenLink/Assets.xcassets/AppIcon.appiconset/Contents.json
  ios/UchidenLink/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png  (1024x1024, 不透明 RGB)
  ios/docs/app-icon.svg  (同じ形状のベクタ。デザインの原本・プレビュー用)

意匠: Android (scripts/gen-icon.py) と同じ「受話器 + その上を渡る橋のアーチ」。
Android はアクセントの地に白い図柄、iOS は Nocturne の濃い地 (bg #0B0B11) に
アクセント系の図柄 (橋 = accent #6B5FD6、受話器 = accentText #C9C2FF)。文字は入れない。
形状 (受話器のパス・アーチ・橋脚) は scripts/gen-icon.py から読み込むので両 OS で一致する。

iOS 26 の単一サイズ形式 (1024 の universal 1 枚)。角丸は OS が付けるので、ここでは正方形の全面を塗る。
App Store のアイコンはアルファを持てないので、PNG は RGB (color type 2) で書く。
"""

import importlib.util
import sys
import json
import os
import struct
import zlib

sys.dont_write_bytecode = True  # scripts/ に __pycache__ を作らない

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)
ROOT = os.path.dirname(IOS)

spec = importlib.util.spec_from_file_location("gen_icon", os.path.join(ROOT, "scripts", "gen-icon.py"))
gi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gi)

SIZE = 1024
BG = (0x0B, 0x0B, 0x11)        # Nocturne bg
BRIDGE = (0x6B, 0x5F, 0xD6)    # Nocturne accent
HANDSET = (0xC9, 0xC2, 0xFF)   # Nocturne accentText
GLYPH_FRACTION = 0.60          # 図柄の外接矩形の長辺がアイコンに占める割合

ASSETS = os.path.join(IOS, "UchidenLink", "Assets.xcassets")
ICONSET = os.path.join(ASSETS, "AppIcon.appiconset")
SVG_OUT = os.path.join(IOS, "docs", "app-icon.svg")


def glyph_parts():
    """108 viewport の輪郭 (受話器 / 橋) を返す。"""
    handset = gi.transform(gi.parse_path(gi.HANDSET_24), gi.HANDSET_SCALE, gi.HANDSET_CX, gi.HANDSET_CY)
    bridge = [gi.arch_contour()] + [gi.circle_contour(cx, cy, gi.PIER_R) for cx, cy in gi.pier_centers()]
    return handset, bridge


def fit(parts, size):
    """全体の外接矩形を中央に置き、長辺が size * GLYPH_FRACTION になるよう拡大する。"""
    pts = [p for part in parts for c in part for p in c]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    s = size * GLYPH_FRACTION / max(max(xs) - min(xs), max(ys) - min(ys))
    return [[[((x - cx) * s + size / 2, (y - cy) * s + size / 2) for x, y in c] for c in part] for part in parts]


def write_rgb_png(path, size, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def blend(base, color, a):
    return tuple(int(round(b + (c - b) * a)) for b, c in zip(base, color))


def render_png(path, size):
    handset, bridge = fit(glyph_parts(), size)
    cov_b = gi.rasterize(bridge, size, size)
    cov_h = gi.rasterize(handset, size, size)
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            i = y * size + x
            px = blend(BG, BRIDGE, cov_b[i])
            px = blend(px, HANDSET, cov_h[i])
            row += bytes(px)
        rows.append(row)
    write_rgb_png(path, size, rows)


def svg_path(contours):
    return " ".join("M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in c) + " Z" for c in contours)


def write_svg(path, size):
    handset, bridge = fit(glyph_parts(), size)
    hexc = lambda c: "#%02X%02X%02X" % c
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">\n'
           f'  <!-- ios/Tools/gen_app_icon.py が生成する。手で編集しない。 -->\n'
           f'  <rect width="{size}" height="{size}" fill="{hexc(BG)}"/>\n'
           f'  <path fill="{hexc(BRIDGE)}" fill-rule="nonzero" d="{svg_path(bridge)}"/>\n'
           f'  <path fill="{hexc(HANDSET)}" fill-rule="nonzero" d="{svg_path(handset)}"/>\n'
           f'</svg>\n')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(svg)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def main():
    write_json(os.path.join(ASSETS, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    write_json(os.path.join(ICONSET, "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    })
    render_png(os.path.join(ICONSET, "AppIcon-1024.png"), SIZE)
    write_svg(SVG_OUT, SIZE)
    print("iOS アプリアイコン生成完了")


if __name__ == "__main__":
    main()
