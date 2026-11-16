# G.711 テストベクタ

Android / iOS の G.711 実装で共有する正解値 (golden)。

| ファイル | 内容 |
|---|---|
| `alaw_decode.txt` | A-law 全 256 コード → 16-bit linear |
| `ulaw_decode.txt` | µ-law 全 256 コード → 16-bit linear |

## 値の規約

- 出力は 16-bit linear PCM。A-law は ITU-T G.711 の 13-bit 値の ×8、µ-law は 14-bit 値の ×4。
- 復号値は各量子化区間の**中点**。ITU-T G.191 STL の `g711.c` (`alaw_expand` / `ulaw_expand`) と
  Sun Microsystems の `g711.c` (`alaw2linear` / `ulaw2linear`) と同じ規約。
- コードは回線上の 8-bit 値 (A-law は偶数ビット反転済み、µ-law はビット反転済み)。

## 作り方

ITU-T G.191 STL (`openitu/STL` の `src/g711/g711.c`) の `alaw_expand()` / `ulaw_expand()` に
0x00〜0xFF を入れて出力を書き出した。STL のソースは ITU-T のライセンスなのでこのリポジトリには置かない。
次の独立した実装と全 256 コードで完全一致することを確認している:
Sun `g711.c` 方式の式、FFmpeg (`-f alaw` / `-f mulaw`)、SoX (`-e a-law` / `-e u-law`)、CPython `audioop`。
iOS 版 (UchidenLinkCore の G711Tests) のアンカー値とも一致する。

## エンコード (16-bit → 8-bit) の丸め規約

エンコードの golden ファイルは置いていない。16-bit の入力を 13-bit (A-law) / 14-bit (µ-law) に
落とすときの負側の丸め方が実装によって違うためである。G.711 の決定境界のちょうど上にある負の入力で、
隣のコードになるかどうかが変わるだけである。全 65536 入力での最大誤差 (復号値 − 入力) は、
µ-law は STL と同じ 644、A-law は STL の 512 に対しアプリは 519 (負側で最大 7 だけ大きい)。

アプリ (Android `G711.kt`) は旧版 Sun `g711.c` の 16-bit 入力形式に従う。STL の `alaw_compress` /
`ulaw_compress` (1 の補数で負を処理) と比べると、次の負の入力だけ 1 段ずれる:

- A-law: 889 入力。例: -17 → 0x55 (STL は 0x54)、-263 → 0x5A (STL は 0x45)
- µ-law: 127 入力。例: -4 → 0x7E (STL は 0x7F)、-124 → 0x6F (STL は 0x70)

この差は規約の違いとして残している。ただし、A-law で -1〜-7 が正の最大値 0xAA になっていた件は
規約の違いではなく不具合なので、STL と同じ 0x55 を正とする。
