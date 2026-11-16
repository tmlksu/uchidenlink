// Package push の APNs VoIP 送信実装 (v1.3)。
//
// APNs provider API (HTTP/2) に token-based 認証 (.p8 の ES256 JWT) で
// VoIP push (apns-push-type: voip) を送る。HTTP/2 は net/http の TLS クライアントが
// ALPN で自動的に選ぶ。
//
// 無効トークン (410 Unregistered / 400 BadDeviceToken) は TokenRemover
// (internal/state.Store) から自動削除する。
//
// 秘密鍵・JWT・トークン全体はログやエラーに出さない (トークンは maskToken で伏せる)。
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	// DefaultAPNsProductionEndpoint は本番 APNs の基底 URL である。
	DefaultAPNsProductionEndpoint = "https://api.push.apple.com"
	// DefaultAPNsDevelopmentEndpoint は開発 (sandbox) APNs の基底 URL である。
	DefaultAPNsDevelopmentEndpoint = "https://api.sandbox.push.apple.com"
	// apnsJWTRefresh は provider token (JWT) を作り直す間隔である。
	// Apple の規定: 有効 60 分以内、再生成は 20 分に 1 回より頻繁にしない。
	apnsJWTRefresh = 50 * time.Minute
	// apnsExpiration は着信 push の有効期限 (PROTOCOL.md の 25 秒応答待ちより少し長い) である。
	apnsExpiration = 30 * time.Second
	// apnsMaxPayload は VoIP push の本文上限 (バイト) である。
	apnsMaxPayload = 4096
)

// APNsConfig は NewAPNs の設定である。
type APNsConfig struct {
	// KeyFile は APNs Auth Key (.p8, PKCS#8 PEM) のパス (APNS_KEY_FILE)。
	// KeyPEM が空のときに読み込む。
	KeyFile string
	// KeyPEM は .p8 の中身。ファイルの代わりに直接渡したい場合に使う (テスト等)。
	KeyPEM []byte
	// KeyID は Auth Key の Key ID (APNS_KEY_ID)。JWT ヘッダ kid に入る。必須。
	KeyID string
	// TeamID は Apple Developer の Team ID (APNS_TEAM_ID)。JWT の iss に入る。必須。
	TeamID string
	// Topic はアプリの bundle ID (APNS_TOPIC)。".voip" を付けて apns-topic にする
	// (既に ".voip" で終わっていればそのまま)。必須。
	Topic string
	// ProductionEndpoint / DevelopmentEndpoint は基底 URL の差し替え (テスト用)。
	// 空なら DefaultAPNsProductionEndpoint / DefaultAPNsDevelopmentEndpoint。
	ProductionEndpoint  string
	DevelopmentEndpoint string
	// HTTPClient の差し替え (テスト用)。nil なら 10 秒タイムアウトの既定品を使う。
	HTTPClient *http.Client
	// Store は無効トークンの削除先。nil なら削除しない。
	Store TokenRemover
	// Now は時計の差し替え (テスト用)。nil なら time.Now。
	Now func() time.Time
	// Log は警告ログの出力先。nil なら slog.Default()。
	Log *slog.Logger
}

// APNs は push.Pusher の APNs VoIP 実装である。
type APNs struct {
	key        *ecdsa.PrivateKey
	keyID      string
	teamID     string
	topic      string
	prodURL    string
	devURL     string
	httpClient *http.Client
	store      TokenRemover
	now        func() time.Time
	log        *slog.Logger

	mu       sync.Mutex
	jwt      string
	issuedAt time.Time
}

// NewAPNs は APNs 送信器を作る。Pusher インタフェースを満たす。
func NewAPNs(cfg APNsConfig) (*APNs, error) {
	var missing []string
	if cfg.KeyID == "" {
		missing = append(missing, "KeyID (APNS_KEY_ID)")
	}
	if cfg.TeamID == "" {
		missing = append(missing, "TeamID (APNS_TEAM_ID)")
	}
	if cfg.Topic == "" {
		missing = append(missing, "Topic (APNS_TOPIC)")
	}
	if len(cfg.KeyPEM) == 0 && cfg.KeyFile == "" {
		missing = append(missing, "鍵 (APNS_KEY_FILE)")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("APNs 設定が不足: %s", strings.Join(missing, ", "))
	}
	keyPEM := cfg.KeyPEM
	if len(keyPEM) == 0 {
		data, err := os.ReadFile(cfg.KeyFile)
		if err != nil {
			return nil, fmt.Errorf("APNs 鍵の読み込み失敗: %w", err)
		}
		keyPEM = data
	}
	key, err := parseAPNsKey(keyPEM)
	if err != nil {
		return nil, err
	}
	topic := cfg.Topic
	if !strings.HasSuffix(topic, ".voip") {
		topic += ".voip"
	}
	prod := cfg.ProductionEndpoint
	if prod == "" {
		prod = DefaultAPNsProductionEndpoint
	}
	dev := cfg.DevelopmentEndpoint
	if dev == "" {
		dev = DefaultAPNsDevelopmentEndpoint
	}
	httpClient := cfg.HTTPClient
	if httpClient == nil {
		// 既定の Transport は TLS の ALPN で HTTP/2 を選ぶ (APNs は HTTP/2 必須)。
		httpClient = &http.Client{Timeout: 10 * time.Second}
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	log := cfg.Log
	if log == nil {
		log = slog.Default()
	}
	return &APNs{
		key:        key,
		keyID:      cfg.KeyID,
		teamID:     cfg.TeamID,
		topic:      topic,
		prodURL:    strings.TrimSuffix(prod, "/"),
		devURL:     strings.TrimSuffix(dev, "/"),
		httpClient: httpClient,
		store:      cfg.Store,
		now:        now,
		log:        log,
	}, nil
}

// parseAPNsKey は .p8 (PKCS#8 PEM の EC P-256 秘密鍵) を読む。
// エラー文に鍵の中身は含めない。
func parseAPNsKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("APNs 鍵が PEM ではない (.p8 を指定すること)")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("APNs 鍵の解析失敗 (PKCS#8 の EC 秘密鍵ではない)")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("APNs 鍵が EC P-256 ではない")
	}
	return key, nil
}

// Topic は apns-topic に使う値 (bundle ID + ".voip") を返す。
func (a *APNs) Topic() string { return a.topic }

// providerToken はキャッシュ済みの JWT を返す。apnsJWTRefresh を過ぎていれば作り直す。
func (a *APNs) providerToken() (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	if a.jwt != "" && now.Sub(a.issuedAt) < apnsJWTRefresh {
		return a.jwt, nil
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"iss": a.teamID,
		"iat": now.Unix(),
	})
	tok.Header["kid"] = a.keyID
	signed, err := tok.SignedString(a.key)
	if err != nil {
		return "", fmt.Errorf("APNs provider token の署名失敗: %w", err)
	}
	a.jwt = signed
	a.issuedAt = now
	return signed, nil
}

// invalidateToken は APNs に拒否された JWT を捨てる (次回作り直す)。
// 並行送信の 1 本が既に作り直していれば (used と異なれば) 何もしない。
func (a *APNs) invalidateToken(used string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.jwt == used {
		a.jwt = ""
	}
}

// apnsPayload は VoIP push の本文である。aps は付けない
// (VoIP push はアプリが PushKit で受けて CallKit に報告する)。
type apnsPayload struct {
	UchidenLink int    `json:"uchidenlink"`
	Type        string `json:"type"`
	CallID      string `json:"callId,omitempty"`
	From        string `json:"from,omitempty"`
	Display     string `json:"display,omitempty"`
}

// encodeAPNsPayload は本文を作る。上限を超える場合は display、次に from を落とす。
func encodeAPNsPayload(p Payload) ([]byte, error) {
	body := apnsPayload{UchidenLink: 1, Type: p.Type, CallID: p.CallID, From: p.From, Display: p.Display}
	if body.Type == "" {
		body.Type = "incoming"
	}
	for {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		if len(data) <= apnsMaxPayload {
			return data, nil
		}
		switch {
		case body.Display != "":
			body.Display = ""
		case body.From != "":
			body.From = ""
		default:
			return nil, fmt.Errorf("APNs payload が %d バイトを超える", apnsMaxPayload)
		}
	}
}

// apnsInvalidTokenError はトークン無効 (410 / BadDeviceToken) を表す。
type apnsInvalidTokenError struct {
	status int
	reason string
}

func (e *apnsInvalidTokenError) Error() string {
	return fmt.Sprintf("APNs トークン無効 (status=%d): %s", e.status, e.reason)
}

// Send は全送信先に VoIP push を送る。Pusher インタフェースの実装である。
//
//   - Env が development なら sandbox、それ以外 (空・production) は本番に送る。
//   - 410 / 400 BadDeviceToken のトークンは削除先から消し、エラーに含めない。
//     それ以外の失敗は errors.Join でまとめて返す (トークンは伏せる)。
//   - 送信は maxSendConcurrency まで並列に行う。
//   - 送信先の Provider は見ない (振り分けは Multi の役目)。
func (a *APNs) Send(ctx context.Context, targets []Target, p Payload) error {
	body, err := encodeAPNsPayload(p)
	if err != nil {
		return err
	}
	var (
		mu   sync.Mutex
		errs []error
		wg   sync.WaitGroup
	)
	sem := make(chan struct{}, maxSendConcurrency)
	for _, t := range targets {
		if t.Token == "" {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(t Target) {
			defer wg.Done()
			defer func() { <-sem }()
			err := a.sendWithRetry(ctx, t, body)
			var invErr *apnsInvalidTokenError
			if errors.As(err, &invErr) {
				if invErr.reason == "BadDeviceToken" {
					a.log.Warn("APNs が BadDeviceToken を返したためトークンを削除 (env の不一致 (development/production) が多い原因)",
						"token", maskToken(t.Token), "env", envOrDefault(t.Env))
				} else {
					a.log.Info("APNs が無効トークンを返したため削除", "token", maskToken(t.Token), "status", invErr.status, "reason", invErr.reason)
				}
				a.removeToken(t.Token)
				return
			}
			if err != nil {
				mu.Lock()
				errs = append(errs, fmt.Errorf("APNs トークン %q (env=%s) への送信失敗: %w", maskToken(t.Token), envOrDefault(t.Env), err))
				mu.Unlock()
			}
		}(t)
	}
	wg.Wait()
	return errors.Join(errs...)
}

// sendWithRetry は 1 送信先に送る。provider token の期限切れ・無効 (403) なら
// JWT を作り直して 1 回だけ再送する。
func (a *APNs) sendWithRetry(ctx context.Context, t Target, body []byte) error {
	used, err := a.sendOne(ctx, t, body)
	var pe *apnsProviderTokenError
	if !errors.As(err, &pe) {
		return err
	}
	a.invalidateToken(used)
	_, err = a.sendOne(ctx, t, body)
	return err
}

// apnsProviderTokenError は 403 ExpiredProviderToken / InvalidProviderToken を表す。
type apnsProviderTokenError struct {
	reason string
}

func (e *apnsProviderTokenError) Error() string {
	return "APNs が provider token を拒否 (403): " + e.reason
}

// apnsErrorResponse は APNs のエラー体である。
type apnsErrorResponse struct {
	Reason string `json:"reason"`
}

// sendOne は 1 回の送信である。使った JWT を返す (再生成の判定用)。
func (a *APNs) sendOne(ctx context.Context, t Target, body []byte) (string, error) {
	bearer, err := a.providerToken()
	if err != nil {
		return "", err
	}
	base := a.prodURL
	if t.Env == EnvDevelopment {
		base = a.devURL
	}
	endpoint := base + "/3/device/" + t.Token
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		// URL を含むエラーはトークンが出るので伏せる。
		return bearer, errors.New("APNs リクエスト作成失敗")
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("authorization", "bearer "+bearer)
	req.Header.Set("apns-push-type", "voip")
	req.Header.Set("apns-topic", a.topic)
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", strconv.FormatInt(a.now().Add(apnsExpiration).Unix(), 10))
	resp, err := a.httpClient.Do(req)
	if err != nil {
		// *url.Error は URL (= トークン) を含むので中身だけを返す。
		var ue *url.Error
		if errors.As(err, &ue) {
			return bearer, fmt.Errorf("APNs への接続失敗: %w", ue.Err)
		}
		return bearer, errors.New("APNs への接続失敗")
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return bearer, fmt.Errorf("APNs 応答読み込み失敗: %w", err)
	}
	if resp.StatusCode == http.StatusOK {
		return bearer, nil
	}
	var er apnsErrorResponse
	_ = json.Unmarshal(respBody, &er)
	switch {
	case resp.StatusCode == http.StatusGone:
		return bearer, &apnsInvalidTokenError{status: resp.StatusCode, reason: orUnknown(er.Reason, "Unregistered")}
	case resp.StatusCode == http.StatusBadRequest && er.Reason == "BadDeviceToken":
		return bearer, &apnsInvalidTokenError{status: resp.StatusCode, reason: er.Reason}
	case resp.StatusCode == http.StatusForbidden &&
		(er.Reason == "ExpiredProviderToken" || er.Reason == "InvalidProviderToken"):
		return bearer, &apnsProviderTokenError{reason: er.Reason}
	}
	return bearer, fmt.Errorf("APNs が %d を返した: %s", resp.StatusCode, orUnknown(er.Reason, strings.TrimSpace(string(respBody))))
}

// removeToken は無効トークンを削除先に伝える。
func (a *APNs) removeToken(token string) {
	if a.store == nil {
		return
	}
	_ = a.store.RemoveToken(token)
}

func envOrDefault(env string) string {
	if env == "" {
		return EnvProduction
	}
	return env
}

func orUnknown(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
