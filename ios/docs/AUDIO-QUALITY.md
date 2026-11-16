# iOS 音声品質の計測と調整 (Phase 2)

方針: 憶測でチューニングしない。`[stats]` / `call_stats` の数値を見て決める (docs/QUALITY_STATS.md と同じ考え方)。

## 計測の仕組み

- 通話中 5 秒ごとに OSLog (category `stats`) へ `[stats]` を 1 行、終話時に `[stats] summary` と
  `[stats] call_stats {…}` (PROTOCOL v1.2、relay 0.3.0 以上なら relay にも送る)。
- 主な項目: `rx` (受信数・欠け・逆転・重複・RFC 3550 jitter・最大到着間隔・stall 100/200/500 ms)、
  `jb` (深さ・目標・underrun・late・overflow・欠けとして飛ばした数・遅延を戻すために捨てた数)、
  `play` (レンダー側のアンダーラン回数と ms、リング残量の最小-最大、フィーダーの遅れ)、
  `tx` (送信数・WS 未接続で送れなかった数・送信エラー・20 ms 周期からの最大遅れ)、`io` (I/O バッファ長)。
- DEBUG 自動テスト: `UCHIDENLINK_AUTODIAL=<内線>` / `UCHIDENLINK_AUTOHANGUP_SEC=<秒>` で起動すると、
  登録後に 1 回発信し、応答から指定秒で終話して `[autotest] result=…` を出す。内線 (2〜4 桁) 以外には発信しない。

```sh
xcrun devicectl device process launch --device <UDID> --terminate-existing --console \
  --environment-variables '{"UCHIDENLINK_AUTODIAL":"2199","UCHIDENLINK_AUTOHANGUP_SEC":"30"}' io.github.tmlksu.uchidenlink
```

## 切り替えられる方式 (DEBUG の環境変数)

| 変数 | 値 | 内容 |
|---|---|---|
| `UCHIDENLINK_JB` | `fixed` (Phase 0a) / `adaptive` (既定) | ジッタバッファ |
| `UCHIDENLINK_FEEDER` | `timer` (Phase 0a) / `level` | ジッタバッファ → 再生リングへの移し方 |
| `UCHIDENLINK_RING_TARGET` | サンプル数 (既定 320 = 40 ms) | `level` がリングに保つ量 |

- `fixed`: 60 ms 先読み・200 ms 上限。欠けは PLC で埋めて再生位置を進め、後から届いた分は捨てる。
- `adaptive`: WSS (TCP) では欠けは起きず「遅れてまとめて届く」ため、空なら再生位置を進めずに待つ。
  late が出たら目標深さを上げ、安定していれば下げ、深すぎるときは静かなフレームを間引いて遅延を戻す。
- `timer`: 20 ms のタイマーで 1 フレームずつ。タイマーとオーディオのクロックがずれるとリングが痩せる/太る。
- `level`: 5 ms ごとにリング残量を見て、足りない分だけ取り出す (取り出しの速さがオーディオのクロックに従う)。

## 結果

### 決定的シミュレーション (UchidenLinkCore `JitterBufferSimulationTests`)
20 ms 送信、3 秒ごとに 300 ms 滞留して一括到着、15 秒:

| 方式 | 捨てた実データ | underrun | 平均深さ |
|---|---|---|---|
| fixed | 52 フレーム | 74 | 1.8 (36 ms) |
| adaptive | 0 | 60 | 4.5 (90 ms) |

### シミュレータ + モック relay (`mock_relay.py --stall-every 3 --stall-ms 300 --jitter-ms 15`)
fixed/timer: `jb.underrun=52 late=52` (途絶ごとに約 13 フレームを PLC で埋めた後、遅れて届いた実データを捨てる)。
シミュレータではオーディオ出力のレンダーがソースノードを引かないため、再生側 (`level` フィーダー・`playUnderrun`) は評価できない。

### 実機 (iPad Air 5th + 本番 relay)

条件: iPad Air (5th) / iPadOS、Wi-Fi、本番 relay 0.3.0 (WSS)、内線 2199 (エコー) に 30 秒、DEBUG 自動テスト。
フィーダーは timer、ring 目標 320 (既定のまま)。

#### 1 回目 (fceff5a): 音声 I/O が回らない
`audio engine started` の直後から、レンダーもマイクのタップも一度も呼ばれなかった
(`tap=0 tx=0`、再生リングが 2048 ms で満杯のまま)。エコーには送る音が無いので下りも途絶え、
3 秒の下り途絶検知で 2 回張り直した (RESUME は 2 回とも成功)。
原因: CallKit がセッションを有効化した直後に `AVAudioEngineConfigurationChange` が来て
エンジンが自分で止まる (5588987 の診断ログで確認: `engine configuration change: engineRunning=false`)。
5588987 で通知を受けて張り直すようにしてからは、毎回 1 回張り直して正常に回る
(1.5 秒後に `renderCalls=58 tapFrames=4800`)。マイク権限が未決定のまま発信しないようにもした。

#### 2 回目以降: 方式の比較 (d38ca21 のビルド)

| 方式 | rx (gaps=ロス) | jitter | maxGap | stall100 | jb underrun | 捨てた実データ | 目標 (終話時) | play underrun |
|---|---|---|---|---|---|---|---|---|
| fixed | 1479 (0) | 25 ms | 136 ms | 31 | 125 | 125 (late) | 3 | 0 |
| adaptive (旧: late だけで目標を上げる) | 1479 (0) | 22 ms | 119 ms | 38 | 210 | 211 (間引き) | 2 | 1 (1 ms) |

- 両方とも tx 1479 / lost 0 / drop 0、txLate 13〜15 ms、RTT 215〜227 ms、gaps・reorder・dup は 0。
- WSS なので欠けは無く、**ほぼ毎秒 1 回、100 ms を超える到着の空白** (その後まとめて届く) がある。
  60 ms の固定先読みではこれを吸収できず、fixed は 30 秒で 125 フレーム (受信の 8.5%) を遅着として捨てた。
- 旧 adaptive は fixed より悪かった。空のとき再生位置を進めずに待つ方式なので late が構造上起きず、
  late だけを契機に目標を上げる作りでは目標が下限 2 (40 ms) に張り付き、途絶のたびに待ち → 溜まった分の間引き、を繰り返した。
- 修正: 待ち (空による underrun) の始まりでも目標を 1 上げる (途絶 1 回につき 1 回)。

実機の到着の仕方 (約 1 秒ごとに 80〜140 ms 滞留、30 秒) を再現したシミュレーション
(`JitterBufferRealPatternTests`):

| 方式 | 捨てた実データ | underrun | 平均深さ | 目標 (終了時) |
|---|---|---|---|---|
| fixed | 78 | 100 | 1.8 (36 ms) | 3 |
| adaptive (旧) | 69 | 91 | 2.1 (42 ms) | 2 |
| adaptive (修正後) | 4 | 26 | 5.2 (104 ms) | 7 |

#### 修正後の adaptive (2d70b3e のビルド) と既定の決定

| 方式 | rx (gaps=ロス) | jitter | maxGap | stall100/200 | jb underrun | 捨てた実データ | 目標 (終話時) | play underrun |
|---|---|---|---|---|---|---|---|---|
| adaptive (修正後) 1 回目 | 1479 (0) | 23 ms | 116 ms | 33 / 0 | 4 | 3 (0.2%) | 5 (100 ms) | 1 (1 ms) |
| adaptive (修正後) 2 回目 | 1479 (0) | 23 ms | 336 ms | 40 / 2 | 23 | 18 (1.2%) | 8 (160 ms) | 9 (23 ms) |
| fixed (同じビルド) | 1488 (0) | 22 ms | 244 ms | 36 / 2 | 163 | 163 (11.0%) | 3 (60 ms) | 10 (24 ms) |

- 修正後の adaptive は、最初の数秒で underrun を契機に目標が 3 → 4 → 5 と上がり、その後はほぼ途切れない。
  網が悪い回 (200 ms 超の空白が 2 回) でも目標 8 まで上げて吸収した。
- fixed は 3 回 (125 / 125 / 163) とも受信の 8〜11% を遅着として捨てている。網の状態に関係なく数字が悪い。
- 代償は遅延: adaptive の目標 5〜8 フレーム = 100〜160 ms (fixed は 60 ms)。ほぼ毎秒の 100 ms 超の空白を
  吸収するのに必要な量で、捨てて途切れるより良い。目標は 10 秒安定するごとに 1 段下がる。

**既定の決定: ジッタバッファは adaptive (修正後)。** 1 回目と 2 回目の 2 回、fixed の 3 回と比べて決めた。
差が大きいので 2180 (aibot) では測っていない。フィーダーは今回比較していないので timer のまま
(play underrun は 30 秒で 1〜10 回・合計 24 ms 以下で、ジッタバッファ由来の欠けより 1 桁小さい)。
DEBUG では `UCHIDENLINK_JB=fixed` で Phase 0a の方式に戻して比較できる。

#### DTMF / ミュート / スピーカー / RESUME (2199 エコー、`UCHIDENLINK_AUTOTEST_STEPS`)
- ミュート (応答 10 秒後〜20 秒後): ミュート中の 5 秒窓は送信も受信 (エコー) も `peak` 0。解除後に戻る。
- DTMF `123` (22 秒後): 送信 peak 32742 (トーン振幅 16383 x 2 の理論値どおり)、エコーで戻った受信 peak 32124 (μ-law の最大値)。
- スピーカー: iPad は受話口が無いので常にスピーカー (経路 `out[Speaker]`)。`speaker=off` は何もしないことを確認。
- RESUME: 1 回目の試験で通話中の張り直しが 2 回起き、2 回とも `hello.call` で同じ呼に戻った。

