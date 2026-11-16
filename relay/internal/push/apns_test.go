package push_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/tmlksu/uchidenlink/relay/internal/push"
)

const (
	testKeyID  = "KEYID12345"
	testTeamID = "TEAMID1234"
	// 64 桁の 16 進トークン (APNs のデバイストークン相当)。
	tokOK      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	tokOK2     = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	tokGone    = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	tokBad     = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
	tokBroken  = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	tokExpired = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
)

// genP8 はテスト用の EC P-256 鍵と、その PKCS#8 PEM (.p8 相当) を作る。
func genP8(t *testing.T) (*ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

// fakeClock は差し替え可能な時計である。
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type apnsRequest struct {
	proto  int
	path   string
	header http.Header
	body   map[string]any
	raw    string
}

// fakeAPNs は APNs provider API を模擬する (1 台のサーバで /prod と /dev を受ける)。
type fakeAPNs struct {
	mu       sync.Mutex
	requests []apnsRequest
	// expireOnce が true のとき、tokExpired 宛ての最初の 1 回は 403 ExpiredProviderToken。
	expireOnce bool
	expired    bool
}

func (f *fakeAPNs) handler(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	var body map[string]any
	_ = json.Unmarshal(raw, &body)
	f.mu.Lock()
	f.requests = append(f.requests, apnsRequest{proto: r.ProtoMajor, path: r.URL.Path, header: r.Header.Clone(), body: body, raw: string(raw)})
	f.mu.Unlock()
	token := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
	w.Header().Set("apns-id", "00000000-0000-0000-0000-000000000000")
	switch token {
	case tokGone:
		w.WriteHeader(http.StatusGone)
		_, _ = w.Write([]byte(`{"reason":"Unregistered","timestamp":1700000000000}`))
	case tokBad:
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"reason":"BadDeviceToken"}`))
	case tokBroken:
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"reason":"InternalServerError"}`))
	case tokExpired:
		f.mu.Lock()
		reject := !f.expireOnce || !f.expired
		f.expired = true
		f.mu.Unlock()
		if reject {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"reason":"ExpiredProviderToken"}`))
			return
		}
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusOK)
	}
}

func (f *fakeAPNs) all() []apnsRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]apnsRequest(nil), f.requests...)
}

type apnsFixture struct {
	apns  *push.APNs
	fake  *fakeAPNs
	key   *ecdsa.PrivateKey
	clock *fakeClock
	rm    *fakeRemover
}

func newTestAPNs(t *testing.T, topic string, tokens ...string) *apnsFixture {
	t.Helper()
	fake := &fakeAPNs{}
	ts := httptest.NewUnstartedServer(http.HandlerFunc(fake.handler))
	ts.EnableHTTP2 = true
	ts.StartTLS()
	t.Cleanup(ts.Close)
	key, p8 := genP8(t)
	clock := &fakeClock{t: time.Unix(1_700_000_000, 0)}
	rm := newFakeRemover(tokens...)
	a, err := push.NewAPNs(push.APNsConfig{
		KeyPEM:              p8,
		KeyID:               testKeyID,
		TeamID:              testTeamID,
		Topic:               topic,
		ProductionEndpoint:  ts.URL + "/prod",
		DevelopmentEndpoint: ts.URL + "/dev/",
		HTTPClient:          ts.Client(),
		Store:               rm,
		Now:                 clock.Now,
	})
	if err != nil {
		t.Fatalf("NewAPNs 失敗: %v", err)
	}
	return &apnsFixture{apns: a, fake: fake, key: key, clock: clock, rm: rm}
}

func apnsTarget(tok, env string) push.Target {
	return push.Target{Provider: push.ProviderAPNsVoIP, Token: tok, Env: env}
}

// parseBearer は authorization ヘッダの JWT を公開鍵で検証して返す。
func (fx *apnsFixture) parseBearer(t *testing.T, h string) (*jwt.Token, jwt.MapClaims) {
	t.Helper()
	if !strings.HasPrefix(h, "bearer ") {
		t.Fatalf("authorization = %q (bearer のはず)", h)
	}
	claims := jwt.MapClaims{}
	tok, err := jwt.ParseWithClaims(strings.TrimPrefix(h, "bearer "), claims, func(*jwt.Token) (any, error) {
		return &fx.key.PublicKey, nil
	}, jwt.WithValidMethods([]string{"ES256"}), jwt.WithoutClaimsValidation())
	if err != nil {
		t.Fatalf("JWT 検証失敗: %v", err)
	}
	return tok, claims
}

func TestNewAPNsValidation(t *testing.T) {
	_, p8 := genP8(t)
	if _, err := push.NewAPNs(push.APNsConfig{KeyPEM: p8, KeyID: "k", Topic: "net.example.app"}); err == nil ||
		!strings.Contains(err.Error(), "APNS_TEAM_ID") {
		t.Errorf("TeamID 空のエラーが不正: %v", err)
	}
	if _, err := push.NewAPNs(push.APNsConfig{KeyFile: "/nonexistent/key.p8", KeyID: "k", TeamID: "t", Topic: "x"}); err == nil {
		t.Errorf("存在しない鍵ファイルでもエラーにならない")
	}
	if _, err := push.NewAPNs(push.APNsConfig{KeyPEM: []byte("not-pem"), KeyID: "k", TeamID: "t", Topic: "x"}); err == nil {
		t.Errorf("PEM でない鍵でもエラーにならない")
	}
	// P-384 は不可。
	k384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(k384)
	if _, err := push.NewAPNs(push.APNsConfig{
		KeyPEM: pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), KeyID: "k", TeamID: "t", Topic: "x",
	}); err == nil {
		t.Errorf("P-384 鍵でもエラーにならない")
	}
	// ファイルから読める。
	path := filepath.Join(t.TempDir(), "key.p8")
	if err := os.WriteFile(path, p8, 0o600); err != nil {
		t.Fatal(err)
	}
	a, err := push.NewAPNs(push.APNsConfig{KeyFile: path, KeyID: "k", TeamID: "t", Topic: "net.example.app.voip"})
	if err != nil {
		t.Fatalf("鍵ファイルからの作成失敗: %v", err)
	}
	if a.Topic() != "net.example.app.voip" {
		t.Errorf("topic = %q (.voip を二重に付けない)", a.Topic())
	}
}

func TestAPNsSendRequest(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app", tokOK)
	p := push.Payload{Type: "incoming", CallID: "c1", From: "09011112222", Display: "テスト"}
	if err := fx.apns.Send(context.Background(), []push.Target{apnsTarget(tokOK, "")}, p); err != nil {
		t.Fatalf("Send 失敗: %v", err)
	}
	reqs := fx.fake.all()
	if len(reqs) != 1 {
		t.Fatalf("リクエスト数 = %d", len(reqs))
	}
	r := reqs[0]
	if r.proto != 2 {
		t.Errorf("HTTP/%d (HTTP/2 のはず)", r.proto)
	}
	if r.path != "/prod/3/device/"+tokOK {
		t.Errorf("path = %q (env 空は production)", r.path)
	}
	for k, want := range map[string]string{
		"apns-push-type":  "voip",
		"apns-topic":      "net.example.app.voip",
		"apns-priority":   "10",
		"apns-expiration": strconv.FormatInt(fx.clock.Now().Unix()+30, 10),
		"content-type":    "application/json",
	} {
		if got := r.header.Get(k); got != want {
			t.Errorf("%s = %q (%q のはず)", k, got, want)
		}
	}
	tok, claims := fx.parseBearer(t, r.header.Get("authorization"))
	if tok.Header["kid"] != testKeyID || tok.Header["alg"] != "ES256" {
		t.Errorf("JWT ヘッダが不正: %v", tok.Header)
	}
	if claims["iss"] != testTeamID {
		t.Errorf("iss = %v", claims["iss"])
	}
	if iat, _ := claims["iat"].(float64); int64(iat) != fx.clock.Now().Unix() {
		t.Errorf("iat = %v", claims["iat"])
	}
	want := map[string]any{"uchidenlink": float64(1), "type": "incoming", "callId": "c1", "from": "09011112222", "display": "テスト"}
	if len(r.body) != len(want) {
		t.Errorf("body = %v", r.body)
	}
	for k, v := range want {
		if r.body[k] != v {
			t.Errorf("body[%q] = %v (%v のはず)", k, r.body[k], v)
		}
	}
	if _, ok := r.body["aps"]; ok {
		t.Errorf("aps は付けない")
	}
}

func TestAPNsPayloadOmitsEmpty(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app")
	if err := fx.apns.Send(context.Background(), []push.Target{apnsTarget(tokOK, "production")}, push.Payload{CallID: "c2"}); err != nil {
		t.Fatalf("Send 失敗: %v", err)
	}
	r := fx.fake.all()[0]
	if r.raw != `{"uchidenlink":1,"type":"incoming","callId":"c2"}` {
		t.Errorf("body = %s", r.raw)
	}
}

func TestAPNsPayloadTooLargeDropsDisplay(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app")
	p := push.Payload{Type: "incoming", CallID: "c3", From: "101", Display: strings.Repeat("あ", 2000)}
	if err := fx.apns.Send(context.Background(), []push.Target{apnsTarget(tokOK, "")}, p); err != nil {
		t.Fatalf("Send 失敗: %v", err)
	}
	r := fx.fake.all()[0]
	if len(r.raw) > 4096 || r.body["display"] != nil || r.body["from"] != "101" {
		t.Errorf("4KB 超の display が落ちていない: %d バイト", len(r.raw))
	}
}

func TestAPNsEnvRouting(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app")
	err := fx.apns.Send(context.Background(), []push.Target{
		apnsTarget(tokOK, "development"),
		apnsTarget(tokOK2, "production"),
		apnsTarget("", "production"), // 空トークンは送らない
	}, push.Payload{Type: "incoming"})
	if err != nil {
		t.Fatalf("Send 失敗: %v", err)
	}
	paths := map[string]bool{}
	for _, r := range fx.fake.all() {
		paths[r.path] = true
	}
	if len(paths) != 2 || !paths["/dev/3/device/"+tokOK] || !paths["/prod/3/device/"+tokOK2] {
		t.Errorf("送信先が不正: %v", paths)
	}
}

func TestAPNsJWTRefresh(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app")
	send := func() (string, float64) {
		t.Helper()
		if err := fx.apns.Send(context.Background(), []push.Target{apnsTarget(tokOK, "")}, push.Payload{}); err != nil {
			t.Fatalf("Send 失敗: %v", err)
		}
		reqs := fx.fake.all()
		h := reqs[len(reqs)-1].header.Get("authorization")
		_, claims := fx.parseBearer(t, h)
		iat, _ := claims["iat"].(float64)
		return h, iat
	}
	h1, iat1 := send()
	fx.clock.Advance(49 * time.Minute)
	h2, iat2 := send()
	if h1 != h2 || iat1 != iat2 {
		t.Errorf("50 分未満で JWT が作り直された")
	}
	fx.clock.Advance(2 * time.Minute)
	h3, iat3 := send()
	if h3 == h1 || int64(iat3) != fx.clock.Now().Unix() {
		t.Errorf("50 分経過で JWT が作り直されない (iat=%v)", iat3)
	}
}

func TestAPNsExpiredProviderTokenRetry(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app", tokExpired)
	fx.fake.expireOnce = true
	if err := fx.apns.Send(context.Background(), []push.Target{apnsTarget(tokExpired, "")}, push.Payload{}); err != nil {
		t.Fatalf("再送で成功するはず: %v", err)
	}
	reqs := fx.fake.all()
	if len(reqs) != 2 {
		t.Fatalf("リクエスト数 = %d (2 のはず)", len(reqs))
	}
	if reqs[0].header.Get("authorization") == reqs[1].header.Get("authorization") {
		t.Errorf("再送で JWT が作り直されていない")
	}
	fx.parseBearer(t, reqs[1].header.Get("authorization"))
	if !fx.rm.has(tokExpired) {
		t.Errorf("403 でトークンが消えた")
	}
}

func TestAPNsExpiredProviderTokenRetryOnlyOnce(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app", tokExpired)
	err := fx.apns.Send(context.Background(), []push.Target{apnsTarget(tokExpired, "")}, push.Payload{})
	if err == nil || !strings.Contains(err.Error(), "ExpiredProviderToken") {
		t.Fatalf("403 が続けばエラーのはず: %v", err)
	}
	if n := len(fx.fake.all()); n != 2 {
		t.Errorf("リクエスト数 = %d (再送は 1 回だけ)", n)
	}
}

func TestAPNsInvalidTokensRemoved(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app", tokOK, tokGone, tokBad)
	err := fx.apns.Send(context.Background(), []push.Target{
		apnsTarget(tokOK, ""), apnsTarget(tokGone, ""), apnsTarget(tokBad, "development"),
	}, push.Payload{Type: "incoming"})
	if err != nil {
		t.Fatalf("410 / BadDeviceToken はエラーにしない: %v", err)
	}
	if fx.rm.has(tokGone) || fx.rm.has(tokBad) {
		t.Errorf("無効トークンが残っている")
	}
	if !fx.rm.has(tokOK) {
		t.Errorf("有効トークンが消えた")
	}
}

func TestAPNsOtherErrorJoined(t *testing.T) {
	fx := newTestAPNs(t, "net.example.app", tokBroken, tokOK)
	err := fx.apns.Send(context.Background(), []push.Target{
		apnsTarget(tokBroken, ""), apnsTarget(tokOK, ""),
	}, push.Payload{Type: "incoming"})
	if err == nil {
		t.Fatalf("500 でもエラーにならない")
	}
	msg := err.Error()
	if !strings.Contains(msg, "500") || !strings.Contains(msg, "InternalServerError") {
		t.Errorf("エラー文が不正: %v", err)
	}
	if strings.Contains(msg, tokBroken) {
		t.Errorf("エラー文にトークン全体が出ている: %v", err)
	}
	if !fx.rm.has(tokBroken) {
		t.Errorf("500 でトークンが消えた")
	}
	if n := len(fx.fake.all()); n != 2 {
		t.Errorf("リクエスト数 = %d (他の端末にも送るはず)", n)
	}
}
