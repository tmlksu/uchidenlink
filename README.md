# ウチ電Link (uchidenlink)

> 旧称 sipbridge から改名した (v1.7.0)。旧パッケージ名 `io.github.tmlksu.sipbridge` で
> 導入済みの端末は、別アプリ扱いになるため入れ直しが必要 (設定も入れ直し)。

宅内 Asterisk を **ポートを開けず・端末側で平文 UDP を待ち受けず・push で着信** できるようにする、
「Asterisk + 変換装置 (relay, Docker) + Android アプリ」構成。

- `DESIGN.md` — 方式検討と採用理由
- `docs/PROTOCOL.md` — relay ⇄ アプリの WebSocket プロトコル (v1.1: SIP アカウントはアプリ側で設定)
- `docs/UI-DESIGN.md` — アプリ画面仕様
- `scripts/` — ビルド/テスト一括 (`check.sh`)・端末投入 (`adb-setup.sh`)・アイコン生成 (`gen-icon.py`)
- `docs/DISTRIBUTION.md` — 配布 (F-Droid を第一ターゲット) の検証結果と残タスク
- `docs/RELEASE.md` — リリース署名 (applicationId / keystore) と GitHub Releases の手順
- `TASKS.md` — 実装タスク分割 (paseo エージェント割当)
- `relay/` — 変換装置 (Go)。SIP サーバ (Asterisk / ひかり電話 HGW など) には SIP/UDP 内線として振る舞い、アプリには Cloudflare Tunnel 越しの WSS を提供
- `deploy/` — Docker/compose/cloudflared
- `android/` — Android アプリ (EchoSIP standby v1.5 から派生)
- `ios/` — iOS アプリ (UchidenLinkCore パッケージ + アプリ本体)
- `docs/echoshow5-device-notes.md` — Echo Show 5 (cronos) の LineageOS 化メモ (参考)

経路: `App ─WSS─▶ Cloudflare (Access: Service Token) ─Tunnel─▶ relay ─SIP/RTP (LAN)─▶ Asterisk`

## ライセンス

Apache License 2.0 (`LICENSE`)。
