#!/usr/bin/env python3
"""spec/ (両 OS 共有の正本) から iOS 用の Swift を生成する。標準ライブラリのみ。

    python3 ios/Tools/gen_spec.py          # 生成
    python3 ios/Tools/gen_spec.py --check  # 生成物が最新か確かめる (差分があれば終了コード 1)

入力:  spec/design-tokens.json, spec/strings.json
出力:  ios/UchidenLink/Generated/DesignTokens.swift, ios/UchidenLink/Generated/L10n.swift

strings.json の書式は Android 形式 (%1$s / %1$d / %1$.1f)。引数がある文言は関数になる
(`L10n.callEndToast("01:08")`)。<b>…</b> は Markdown の **…** に変換する
(SwiftUI では Text(LocalizedStringKey(…)) で太字になる)。platforms に ios を含まない項目は出さない。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "spec"
OUT = ROOT / "ios" / "UchidenLink" / "Generated"

HEADER = "// 生成ファイル: 手で編集しない。正本は spec/{src}、生成は ios/Tools/gen_spec.py。\n"


def camel(name: str) -> str:
    parts = name.split("_")
    return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])


def swift_string_literal(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def hex_to_rgb(h: str):
    h = h.lstrip("#")
    if len(h) != 6:
        raise ValueError(f"bad color {h}")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def gen_tokens() -> str:
    t = json.loads((SPEC / "design-tokens.json").read_text(encoding="utf-8"))
    lines = [HEADER.format(src="design-tokens.json"), "import SwiftUI", "",
             "/// Nocturne デザイントークン (UI-DESIGN.md §0)。", "enum Nocturne {"]
    for name, c in t["colors"].items():
        r, g, b = hex_to_rgb(c["value"])
        lines.append(f"    /// {c['value']} — {c.get('use', '')}")
        lines.append(f"    static let {name} = Color(red: {r:.4f}, green: {g:.4f}, blue: {b:.4f})")
    for group in ("radius", "size", "font"):
        lines.append("")
        lines.append(f"    enum {group.capitalize()} {{")
        for name, v in t[group].items():
            lines.append(f"        static let {name}: CGFloat = {v}")
        lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"


FMT = re.compile(r"%(\d+)\$(s|d|\.\d+f)")


def gen_strings() -> str:
    doc = json.loads((SPEC / "strings.json").read_text(encoding="utf-8"))
    lines = [HEADER.format(src="strings.json"), "import Foundation", "",
             "/// 画面文言 (spec/strings.json)。キーは Android のリソース名を camelCase にしたもの。",
             "enum L10n {"]
    for key, entry in doc["strings"].items():
        plats = entry.get("platforms")
        if plats is not None and "ios" not in plats:
            continue
        text = entry["ja"]
        text = re.sub(r"<b>(.*?)</b>", r"**\1**", text)
        if "<" in text:
            raise ValueError(f"{key}: unsupported markup")
        args = sorted({(int(n), kind) for n, kind in FMT.findall(text)})
        name = camel(key)
        if not args:
            if "%" in text.replace("%%", ""):
                raise ValueError(f"{key}: stray %")
            lines.append(f"    static let {name} = {swift_string_literal(text.replace('%%', '%'))}")
            continue
        if [n for n, _ in args] != list(range(1, len(args) + 1)):
            raise ValueError(f"{key}: argument numbers must be 1..n")
        params, swift_fmt = [], text
        for n, kind in args:
            if kind == "s":
                params.append(f"_ a{n}: String")
                swift_fmt = swift_fmt.replace(f"%{n}$s", f"%{n}$@")
            elif kind == "d":
                params.append(f"_ a{n}: Int")
                swift_fmt = swift_fmt.replace(f"%{n}$d", f"%{n}$ld")
            else:
                params.append(f"_ a{n}: Double")
        call_args = ", ".join(f"a{n}" for n, _ in args)
        lines.append(f"    static func {name}({', '.join(params)}) -> String {{")
        lines.append(f"        String(format: {swift_string_literal(swift_fmt)}, {call_args})")
        lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    check = "--check" in sys.argv[1:]
    outputs = {OUT / "DesignTokens.swift": gen_tokens(), OUT / "L10n.swift": gen_strings()}
    stale = []
    for path, content in outputs.items():
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current != content:
            stale.append(path)
            if not check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
    if check and stale:
        for p in stale:
            print(f"stale: {p.relative_to(ROOT)}", file=sys.stderr)
        return 1
    for p in stale:
        print(f"wrote {p.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
