package push_test

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"testing"

	"github.com/tmlksu/uchidenlink/relay/internal/push"
)

func TestNoop(t *testing.T) {
	var p push.Pusher = push.Noop{}
	if err := p.Send(context.Background(), []push.Target{{Provider: push.ProviderFCM, Token: "a"}}, push.Payload{Type: "incoming"}); err != nil {
		t.Errorf("Noop は nil を返すはず: %v", err)
	}
}

// recordPusher は受け取った送信先を記録する。
type recordPusher struct {
	mu      sync.Mutex
	targets []push.Target
	err     error
}

func (r *recordPusher) Send(_ context.Context, ts []push.Target, _ push.Payload) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.targets = append(r.targets, ts...)
	return r.err
}

func TestMultiRoutesByProvider(t *testing.T) {
	f, a := &recordPusher{}, &recordPusher{}
	m := &push.Multi{FCM: f, APNs: a}
	err := m.Send(context.Background(), []push.Target{
		{Provider: "fcm", Token: "f1"},
		{Provider: "", Token: "f2"}, // 空は fcm
		{Provider: "apns-voip", Token: "a1", Env: "development"},
		{Provider: "apns-voip", Token: ""}, // 空トークンは捨てる
	}, push.Payload{Type: "incoming"})
	if err != nil {
		t.Fatalf("Send 失敗: %v", err)
	}
	if len(f.targets) != 2 || f.targets[0].Token != "f1" || f.targets[1].Token != "f2" {
		t.Errorf("FCM 宛てが不正: %+v", f.targets)
	}
	if len(a.targets) != 1 || a.targets[0] != (push.Target{Provider: "apns-voip", Token: "a1", Env: "development"}) {
		t.Errorf("APNs 宛てが不正: %+v", a.targets)
	}
}

func TestMultiSkipsUnconfiguredProvider(t *testing.T) {
	var logBuf bytes.Buffer
	f := &recordPusher{}
	var nilAPNs *push.APNs
	m := &push.Multi{FCM: f, APNs: nilAPNs, Log: slog.New(slog.NewTextHandler(&logBuf, nil))}
	err := m.Send(context.Background(), []push.Target{
		{Provider: "fcm", Token: "f1"},
		{Provider: "apns-voip", Token: "a1"},
		{Provider: "apns-voip", Token: "a2"},
		{Provider: "unknown", Token: "u1"},
	}, push.Payload{Type: "incoming"})
	if err != nil {
		t.Fatalf("未設定 provider はエラーにしない: %v", err)
	}
	if len(f.targets) != 1 {
		t.Errorf("FCM 宛てが送られない: %+v", f.targets)
	}
	if n := strings.Count(logBuf.String(), "provider=apns-voip"); n != 1 {
		t.Errorf("apns-voip の警告が %d 回 (1 回のはず): %s", n, logBuf.String())
	}
	if !strings.Contains(logBuf.String(), "provider=unknown") {
		t.Errorf("未知 provider の警告が無い: %s", logBuf.String())
	}
}

func TestMultiJoinsErrors(t *testing.T) {
	f := &recordPusher{err: errors.New("fcm-fail")}
	a := &recordPusher{}
	m := &push.Multi{FCM: f, APNs: a}
	err := m.Send(context.Background(), []push.Target{
		{Provider: "fcm", Token: "f1"}, {Provider: "apns-voip", Token: "a1"},
	}, push.Payload{})
	if err == nil || !strings.Contains(err.Error(), "fcm-fail") {
		t.Errorf("FCM のエラーが返らない: %v", err)
	}
	if len(a.targets) != 1 {
		t.Errorf("FCM の失敗で APNs が送られない")
	}
}

func TestNormalizeRegistration(t *testing.T) {
	hex64 := strings.Repeat("Ab", 32)
	ok := []struct {
		provider, token, env string
		wantTok, wantEnv     string
	}{
		{"fcm", "fcm-token:xyz", "development", "fcm-token:xyz", ""},
		{"apns-voip", hex64, "", strings.ToLower(hex64), "production"},
		{"apns-voip", hex64, "development", strings.ToLower(hex64), "development"},
		{"apns-voip", strings.Repeat("0", 200), "production", strings.Repeat("0", 200), "production"},
	}
	for _, c := range ok {
		tok, env, err := push.NormalizeRegistration(c.provider, c.token, c.env)
		if err != nil || tok != c.wantTok || env != c.wantEnv {
			t.Errorf("%s/%q/%q → (%q, %q, %v)", c.provider, c.token, c.env, tok, env, err)
		}
	}
	bad := []struct{ provider, token, env string }{
		{"", "tok", ""},
		{"fcm", "", ""},
		{"apns", hex64, ""},
		{"apns-voip", strings.Repeat("a", 63), ""},
		{"apns-voip", strings.Repeat("a", 201), ""},
		{"apns-voip", strings.Repeat("g", 64), ""},
		{"apns-voip", hex64, "sandbox"},
	}
	for _, c := range bad {
		if _, _, err := push.NormalizeRegistration(c.provider, c.token, c.env); err == nil {
			t.Errorf("%s/%q/%q がエラーにならない", c.provider, c.token, c.env)
		}
	}
}
