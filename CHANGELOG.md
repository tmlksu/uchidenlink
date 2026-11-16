# 変更履歴

## v1.7.0 (2026-11-17)

- プロジェクト名を **ウチ電Link (uchidenlink)** に改名し、リポジトリを作り直した
  (旧リポジトリの履歴は引き継がない単一コミットからの再出発)。
- applicationId / bundle ID: `io.github.tmlksu.sipbridge` → `io.github.tmlksu.uchidenlink`。
  旧アプリからの上書き更新はできない (アンインストールして入れ直し、設定も入れ直し)。
- iOS アプリを追加 (Android と同一内線を共有し、着信は全端末にファンアウト)。
- Android: G.711 A-law のデコード表を ITU 標準に合わせ、-1〜-7 のエンコード不具合を修正
  (ITU 標準ベクタによるテストを追加)。
- relay 0.5.0: Go モジュールパスと環境変数名を改名に合わせて変更
  (`UCHIDENLINK_*`。移行時は relay の env ファイル側も合わせて変更すること)。

## それ以前 (旧称 sipbridge 時代)

- **v1.6.0** — リリース。
- **v1.5.4 / v1.5.2 / v1.5.1 / v1.5** — 細かな修正。
- **v1.5.3** — resume 猶予と通話中の再接続バックオフの整合、網切替を NetworkCallback で
  検知して即再接続、WS 制御メッセージの送信失敗を再接続後に再送、FCM 並列送信、
  wake lock の定期的な取り直し、ほか。
- **v1.4** — リリース。
- **v1.3** — applicationId を `io.github.tmlksu.sipbridge` に変更。
- **v1.2** — リリース。
