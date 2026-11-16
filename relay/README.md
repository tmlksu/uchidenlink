# relay (uchidenlink 変換装置)

Asterisk には SIP/UDP 内線として振る舞い、アプリには
`wss://<host>/v1/session` (JSON 制御 + RTP バイナリ) を提供する。
プロトコルは `../docs/PROTOCOL.md`。

## 起動 (開発用)

```sh
cd relay
export PATH=$HOME/go-toolchain/go/bin:$PATH
BACKEND=fake AUTH_MODE=token DEV_TOKEN=x LISTEN=127.0.0.1:8080 \
  STATE_FILE=/tmp/uchidenlink-state.json go run ./cmd/relay
curl localhost:8080/healthz   # {"status":"ok"}
```

## 環境変数

| 変数 | 既定 | 説明 |
|---|---|---|
| `LISTEN` | `127.0.0.1:8080` | 待ち受けアドレス |
| `AUTH_MODE` | `token` | `cf-access`\|`token` |
| `CF_TEAM_DOMAIN` | (無) | cf-access 時に必須 (例 `example.cloudflareaccess.com`)。`https://`・末尾 `/` は除去、小文字化。JWT の `iss` は `https://<この値>` を要求 |
| `CF_ACCESS_AUD` | (無) | cf-access 時に必須 (Access の AUD タグ) |
| `DEV_TOKEN` | (無) | `token` 時に必須 (`Authorization: Bearer`) |
| `ALLOW_INSECURE_LISTEN` | `0` | `1` で `AUTH_MODE=token` の非 loopback `LISTEN` を許す (既定は起動エラー) |
| `DEVICE_BINDING` | `warn` | `off`\|`warn`\|`enforce`。端末 ID と Access の認証主体の TOFU 結び付け (docs/SECURITY.md §5) |
| `MAX_ACCOUNTS` | `16` | SIP アカウント数の上限 (新規作成時のみ) |
| `MAX_STORED_DEVICES` | `64` | 状態ファイルに保存する端末数の上限 (新規保存時のみ) |
| `MAX_ONLINE_DEVICES` | `32` | 同時接続の端末数の上限 (接続中・保存済みの端末は対象外) |
| `SIP_HOST/SIP_PORT` | `127.0.0.1:5060` | sip バックエンドの対向 SIP サーバ。Asterisk に限らず任意のレジストラでよい (例: ひかり電話 HGW の LAN 側 IP)。旧名 `ASTERISK_HOST/ASTERISK_PORT` も読む |
| `SIP_TRUSTED_SOURCES` | (空) | SIP 要求・RTP を受け付ける追加の送信元 (CIDR / IP のカンマ区切り)。既定では `SIP_HOST` の解決結果と同居時の自ホストのみ受け付ける (docs/SECURITY.md §9) |
| `SIP_USER/PASSWORD/DISPLAY` | (無) | **任意**の既定アカウント (v1.1)。設定するとアカウント未設定の端末が暫定的に結び付く (永続化しない)。SIP アカウントは通常アプリが `sip_account` で登録する |
| `LOCAL_IP` | (自動) | T2 の SDP/Contact 用 |
| `RTP_PORT_MIN/MAX` | `20000/20100` | T2 の RTP 用 |
| `BACKEND` | `fake` | `fake`\|`sip` (sip: 実 SIP サーバ対向の本番用) |
| `RESUME_TIMEOUT_SEC` | `30` | 通話中に WS が切れてから BYE するまでの猶予 (1..300)。アプリの再接続が収まる値にする |
| `WS_PING_INTERVAL` | `20s` | relay→app の WS ping 周期 (5s..5m。`45s` 形式または整数秒)。Cloudflare の WS アイドル切断 (~100 秒) より短くする。待機コスト計測 (docs/QUALITY_STATS.md E1) 用 |
| `LOG_LEVEL` | `info` | debug\|info\|warn\|error |
| `STATE_FILE` | `/var/lib/uchidenlink/state.json` | 状態ファイル (account / 端末結び付け / push トークン, 0600)。旧名 `PUSH_STATE_FILE` も読み、旧形式は起動時に自動移行 |
| `FCM_PROJECT_ID` | (無) | FCM 送信に使用 (Firebase プロジェクト ID)。空なら FCM は無効 |
| `FCM_SERVICE_ACCOUNT_FILE` | (無) | FCM 送信に使用 (サービスアカウント JSON のパス)。`FCM_PROJECT_ID` と対 |
| `APNS_KEY_FILE` | (無) | APNs VoIP 送信 (iOS, v1.3) に使用。APNs Auth Key (`.p8`) のパス。読めなければ起動エラー |
| `APNS_KEY_ID` | (無) | APNs Auth Key の Key ID (10 文字) |
| `APNS_TEAM_ID` | (無) | Apple Developer の Team ID |
| `APNS_TOPIC` | (無) | アプリの bundle ID (例 `net.example.app`)。`.voip` は relay が付ける (付いていればそのまま) |

`APNS_*` の 4 つはすべて設定で APNs 有効、すべて空で無効。一部だけ設定すると起動エラー (足りない変数名を表示)。
FCM と APNs はそれぞれ独立に有効化でき、どちらも無ければ push は no-op。

## サブコマンド

- `relay healthcheck`: `LISTEN` の `/healthz` を GET し 200 なら exit 0
  (Docker HEALTHCHECK 用。scratch イメージに curl が無いため)。

## push 送信 (FCM)

`internal/push` の `FCM` が `Pusher` インタフェースを満たす。配線は
`cmd/relay/main.go` で行う。配線例:

```go
store, _ := state.New(cfg.StateFile)
var pusher push.Pusher = push.Noop{}
if cfg.FCMProjectID != "" && cfg.FCMServiceAccountFile != "" {
    fcm, err := push.NewFCM(push.FCMConfig{
        ProjectID:          cfg.FCMProjectID,
        ServiceAccountFile: cfg.FCMServiceAccountFile,
        Store:              store, // UNREGISTERED トークンの自動削除先 (push.TokenRemover)
    })
    if err != nil {
        return err
    }
    pusher = fcm
}
hub := session.NewHub(factory, pusher, store, ...)
```

仕様:

- FCM HTTP v1 (`POST https://fcm.googleapis.com/v1/projects/<id>/messages:send`)。
  OAuth2 はサービスアカウント JSON から `golang.org/x/oauth2/google` で取得
  (スコープ `https://www.googleapis.com/auth/firebase.messaging`)。
- data message `{type, callId, caller, display}` (空欄は省略。`from` は FCM の予約キーの
  ため `caller` を使う) + `android.priority=HIGH` +
  `ttl=30s` (PROTOCOL.md の 25 秒応答待ちより少し長い)。
- `404/UNREGISTERED` と判定したトークンは `push.TokenRemover`
  (`internal/state.Store` が実装) から削除し、`Send` はエラーに含めない。
  それ以外の失敗は `errors.Join` で返す。
- テスト時は `FCMConfig.Endpoint` に `httptest` サーバ URL、`TokenSource` に
  `oauth2.StaticTokenSource` を渡す (`fcm_test.go` 参照)。

## push 送信 (APNs VoIP, v1.3)

`internal/push` の `APNs` (iOS PushKit 用) も `Pusher` を満たす。`push.Multi` が送信先
(`push.Target{Provider, Token, Env}`) の provider ごとに `FCM` / `APNs` へ振り分け、両方を並行に送る
(同じ account に Android と iOS が混在してよい。未設定の provider 宛ては送らず、Send ごとに 1 回警告ログ)。
配線は `cmd/relay/main.go`。

仕様 (プロトコル側は `docs/PROTOCOL.md`「APNs VoIP push (v1.3)」):

- `POST /3/device/<token>` を `env` に応じて `https://api.push.apple.com` (production) /
  `https://api.sandbox.push.apple.com` (development) へ。HTTP/2 は `net/http` が ALPN で自動選択する。
  ヘッダ `apns-push-type: voip`、`apns-topic: <APNS_TOPIC>.voip`、`apns-priority: 10`、
  `apns-expiration: now+30`、`authorization: bearer <JWT>`。HTTP タイムアウト 10 秒、同時 8 本まで。
- JWT は `.p8` (PKCS#8 の EC P-256) で ES256 署名 (`kid=APNS_KEY_ID`、`iss=APNS_TEAM_ID`、`iat`)。
  キャッシュして 50 分ごとに作り直す (Apple: 有効 60 分、再生成は 20 分に 1 回まで)。
  403 `ExpiredProviderToken` / `InvalidProviderToken` なら作り直して 1 回だけ再送する。
- 本文 `{"uchidenlink":1,"type":"incoming","callId","from","display"}` (空は省略、`aps` 無し)。
- 410 / 400 `BadDeviceToken` のトークンは `push.TokenRemover` (状態ファイル) から削除し、エラーにしない
  (`BadDeviceToken` は env の取り違えが多いので警告ログを出す)。それ以外の失敗は `errors.Join` で返す。
- 鍵・JWT・トークン全体はログに出さない (トークンは先頭/末尾 4 文字のみ)。
- テストは `httptest` の TLS サーバ (HTTP/2) を `APNsConfig.ProductionEndpoint` /
  `DevelopmentEndpoint` / `HTTPClient` に、時計を `Now` に渡す (`apns_test.go` 参照)。

### APNs Auth Key の用意

1. Apple Developer の「Certificates, IDs & Profiles」→「Keys」で新しい鍵を作り、
   「Apple Push Notifications service (APNs)」を有効にする。`.p8` は作成直後に 1 回だけダウンロードできる。
2. 鍵の **Key ID** (鍵の詳細画面) と **Team ID** (Membership 画面) を控える。
3. `.p8` を relay ホストに置き、relay の実行ユーザーだけが読めるようにする (`chmod 600`。
   Docker 構成なら `deploy/data/` に `install -m 600 -o 65532 -g 65532` で置くと
   コンテナ内では `/var/lib/uchidenlink/` 配下に見える)。
4. `.env` に `APNS_KEY_FILE=<.p8 のパス>`、`APNS_KEY_ID`、`APNS_TEAM_ID`、`APNS_TOPIC=<bundle ID>` を設定して再起動する。
   起動ログに `push: APNs VoIP 有効` が出れば有効。
5. `.p8` は **絶対に commit しない** (1 つの鍵で同じ Team の全アプリに push できる)。漏れたら portal で失効させる。

## マルチアカウント (v1.1)

1 プロセスで複数の SIP アカウント (内線) を扱う。account ごとに
「グループ」(Backend + `call.Manager` + 所属接続 + 勝者 + メディアポンプ) を持つ。

- 端末は `sip_account {user,password,display}` でアカウントに結び付く。
  結び付けと資格情報は `STATE_FILE` に永続化され、起動時に全アカウントの
  REGISTER を開始する (端末が未接続でも登録を維持する)。
- 結び付いた端末が 0 になったらグループを停止し、state から account を消す
  (既定アカウント `SIP_USER` は常駐)。
- 保存値と違うパスワードが来たら `error account_password_mismatch`。例外はそのアカウントに
  結び付いた端末からの未登録中の送信で、パスワード変更として Backend を作り直す。Backend 生成失敗は
  `error account_failed`。新規アカウントとパスワード変更は REGISTER 成功まで仮で、認証拒否が 3 回以上かつ
  最初の拒否から 2 分以上続くと削除 / 差し戻しする (`error account_failed`)。試行制限・上限は
  docs/SECURITY.md §3。
- アカウント未設定の端末が `answer/reject/hangup/dial` を送ると `error no_account`。
- 停止時 (グループ停止・プロセス終了) は REGISTER `Expires: 0` を 1 回送る。
- ロック順序は `hub.mu → group.mu` の一方向のみ。

## wsprobe (E2E 用 WS プローブ)

```sh
CGO_ENABLED=0 go build ./cmd/wsprobe

# 発信側 (101 として接続し 102 へ発信、5 秒通話して切断)
./wsprobe -url ws://127.0.0.1:18080 -token dev -device probe-101 \
  -account 101:test101pass -expect-registered \
  -dial 102 -talk 5s -hangup-after 5s -expect-ended

# 着信側 (102 として接続し、着信を待って応答)
./wsprobe -url ws://127.0.0.1:18080 -token dev -device probe-102 \
  -account 102:test102pass -expect-registered \
  -wait-incoming -answer -talk 5s -expect-ended -timeout 60s
```

結果は 1 行 JSON (`{"hello":…,"registered":…,"incoming":…,"answered":…,
"rtpSent":n,"rtpRecv":n,"ended":…,"errors":[]}`) を stdout に出し、
期待に反したら exit 1。`-json` で stderr の進捗ログを止める。
`-cf-id/-cf-secret` で Cloudflare Access Service Token を使える。

## 開発

```sh
export PATH=$HOME/go-toolchain/go/bin:$PATH
gofmt -l . && go vet ./... && go test ./...   # 全てクリーンであること
CGO_ENABLED=0 go build ./cmd/relay ./cmd/wsprobe   # 静的バイナリ

# Asterisk 結合テスト (docker compose -f ../deploy/test/compose.yml up -d が必要)
go test -tags integration ./...
```

## 構成

- `internal/config`: 環境変数の読み込みと検証
- `internal/proto`: PROTOCOL.md の JSON 型と encode/decode
- `internal/auth`: `TokenAuth` / `CFAccessAuth` (JWKS 10 分キャッシュ、RS256、`aud`/`exp` 検証)
- `internal/call`: 単一通話の状態機械 (`Backend` インタフェース)
- `internal/fakebackend`: テスト用バックエンド (`InjectIncoming`、`Answer` 後はエコー)
- `internal/push`: `Pusher` インタフェース + no-op、FCM HTTP v1 送信 (`fcm.go`)。無効トークン (404/UNREGISTERED) は `TokenRemover` 経由で自動削除
- `internal/state`: 状態ファイル (version 2: accounts / devices{account, push{provider, token, env}}) の読み書き。旧形式の自動移行、0600 で tmp→rename の原子的書き込み
- `internal/sipbackend`: sipgo による `call.Backend` 実装 (REGISTER/UAS/UAC/RTP)
- `internal/session`: WS セッション管理 (`X-Device-Id` 単位、account グループ、`hello`、20 秒 ping、fanout、勝者のみ中継)
- `cmd/wsprobe`: E2E 用 WS プローブ CLI

## 外から SIP UA を使う (`relay/sipua`)

relay の SIP UA (Asterisk に内線として REGISTER し、着信・発信・RTP を扱う部分) は
`github.com/tmlksu/uchidenlink/relay/sipua` から使える (中身は `internal/sipbackend` と
`internal/call` の型の別名。テスト用の偽 Backend は `sipua/sipuatest`)。
relay とは別に動く SIP 内線アプリ (AI 内線など) から使う。ここに出した名前は消したり意味を変えたりしない。
