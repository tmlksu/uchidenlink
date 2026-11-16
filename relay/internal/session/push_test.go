package session_test

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/tmlksu/uchidenlink/relay/internal/proto"
	"github.com/tmlksu/uchidenlink/relay/internal/push"
	"github.com/tmlksu/uchidenlink/relay/internal/state"
)

// recordingPusher は Send の呼び出しを記録する検証用 Pusher である。
type recordingPusher struct {
	mu    sync.Mutex
	calls []pushCall
	ch    chan pushCall
}

type pushCall struct {
	tokens  []string
	targets []push.Target
	payload push.Payload
}

func newRecordingPusher() *recordingPusher {
	return &recordingPusher{ch: make(chan pushCall, 8)}
}

func (p *recordingPusher) Send(_ context.Context, targets []push.Target, pl push.Payload) error {
	c := pushCall{targets: append([]push.Target(nil), targets...), payload: pl}
	for _, t := range targets {
		c.tokens = append(c.tokens, t.Token)
	}
	p.mu.Lock()
	p.calls = append(p.calls, c)
	p.mu.Unlock()
	select {
	case p.ch <- c:
	default:
	}
	return nil
}

// count は記録済みの Send 呼び出し回数である。
func (p *recordingPusher) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.calls)
}

// wait は Send が呼ばれるまで待つ (Send は非同期実行のため)。
func (p *recordingPusher) wait(t *testing.T, d time.Duration) pushCall {
	t.Helper()
	select {
	case c := <-p.ch:
		return c
	case <-time.After(d):
		t.Fatalf("push が %v 以内に送られない", d)
		return pushCall{}
	}
}

// registerPush は register_push を送り、ping/pong で処理完了を待つ。
func registerPush(t *testing.T, ws *websocket.Conn, token string, ts int64) {
	t.Helper()
	writeJSON(t, ws, &proto.RegisterPush{T: proto.TRegisterPush, Provider: "fcm", Token: token})
	writeJSON(t, ws, &proto.Ping{T: proto.TPing, Ts: ts})
	pong, ok := readJSON(t, ws).(*proto.Pong)
	if !ok || pong.Ts != ts {
		t.Fatalf("pong が不正: %+v", pong)
	}
}

// waitSessions は WS 接続数が want になるまで待つ (切断処理は非同期のため)。
func waitSessions(t *testing.T, fx *fixture, want int, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if fx.hub.SessionCount() == want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("接続数が %d にならない (現在 %d)", want, fx.hub.SessionCount())
}

// TestPushOnlyToOfflineDevices は着信 push が
// 「登録済みかつ WS 未接続」のデバイスだけに送られることを確認する。
// dev-A は push 登録後に切断、dev-B は接続したまま。
func TestPushOnlyToOfflineDevices(t *testing.T) {
	rp := newRecordingPusher()
	fx := newFixtureWithPusher(t, rp)

	a := dial(t, fx.url, "dev-A")
	if _, ok := readJSON(t, a).(*proto.Hello); !ok {
		t.Fatalf("A に hello が来ない")
	}
	registerPush(t, a, "tok-A", 1)
	_ = a.Close(websocket.StatusNormalClosure, "")

	b := dial(t, fx.url, "dev-B")
	defer b.Close(websocket.StatusNormalClosure, "")
	if _, ok := readJSON(t, b).(*proto.Hello); !ok {
		t.Fatalf("B に hello が来ない")
	}
	registerPush(t, b, "tok-B", 2)
	waitSessions(t, fx, 1, 3*time.Second) // A の切断が反映されるまで

	fx.fb(t).InjectIncoming("102", "Bob", 0)
	inc, ok := readJSON(t, b).(*proto.Incoming)
	if !ok {
		t.Fatalf("B に incoming が来ない")
	}

	c := rp.wait(t, 3*time.Second)
	if len(c.tokens) != 1 || c.tokens[0] != "tok-A" {
		t.Fatalf("push 先が不正: %v (tok-A のみのはず)", c.tokens)
	}
	if c.payload.Type != "incoming" || c.payload.CallID != inc.CallID ||
		c.payload.From != "102" || c.payload.Display != "Bob" {
		t.Fatalf("payload が不正: %+v", c.payload)
	}
}

// TestNoPushWhenAllDevicesOnline は全登録デバイスが接続中なら
// push を送らないことを確認する。
func TestNoPushWhenAllDevicesOnline(t *testing.T) {
	rp := newRecordingPusher()
	fx := newFixtureWithPusher(t, rp)

	a := dial(t, fx.url, "dev-A")
	defer a.Close(websocket.StatusNormalClosure, "")
	if _, ok := readJSON(t, a).(*proto.Hello); !ok {
		t.Fatalf("A に hello が来ない")
	}
	registerPush(t, a, "tok-A", 1)

	fx.fb(t).InjectIncoming("102", "Bob", 0)
	if _, ok := readJSON(t, a).(*proto.Incoming); !ok {
		t.Fatalf("A に incoming が来ない")
	}

	select {
	case c := <-rp.ch:
		t.Fatalf("接続中デバイスに push が送られた: %v", c.tokens)
	case <-time.After(300 * time.Millisecond):
	}
	if n := rp.count(); n != 0 {
		t.Fatalf("Send 呼び出し回数 = %d (0 のはず)", n)
	}
}

// sendRegister は任意の register_push を送り、エラー応答 (無ければ nil) を返す。
func sendRegister(t *testing.T, ws *websocket.Conn, m *proto.RegisterPush, ts int64) *proto.Error {
	t.Helper()
	m.T = proto.TRegisterPush
	writeJSON(t, ws, m)
	writeJSON(t, ws, &proto.Ping{T: proto.TPing, Ts: ts})
	switch v := readJSON(t, ws).(type) {
	case *proto.Error:
		if pong, ok := readJSON(t, ws).(*proto.Pong); !ok || pong.Ts != ts {
			t.Fatalf("エラーの後に pong が来ない: %+v", pong)
		}
		return v
	case *proto.Pong:
		if v.Ts != ts {
			t.Fatalf("pong が不正: %+v", v)
		}
		return nil
	default:
		t.Fatalf("想定外の応答: %+v", v)
		return nil
	}
}

// TestRegisterPushAPNs は apns-voip の検証・正規化・env の保存を確認する。
func TestRegisterPushAPNs(t *testing.T) {
	fx := newFixture(t)
	ws := dial(t, fx.url, "dev-I")
	defer ws.Close(websocket.StatusNormalClosure, "")
	if _, ok := readJSON(t, ws).(*proto.Hello); !ok {
		t.Fatalf("hello が来ない")
	}
	hex64 := strings.Repeat("AB", 32)
	for i, bad := range []proto.RegisterPush{
		{Provider: "apns", Token: hex64},
		{Provider: "apns-voip", Token: "not-hex"},
		{Provider: "apns-voip", Token: strings.Repeat("a", 63)},
		{Provider: "apns-voip", Token: hex64, Env: "sandbox"},
		{Provider: "", Token: "x"},
	} {
		m := bad
		if e := sendRegister(t, ws, &m, int64(10+i)); e == nil || e.Code != "bad_message" {
			t.Errorf("%+v → %+v (bad_message のはず)", bad, e)
		}
	}
	if _, ok := fx.store.Device("dev-I"); ok {
		t.Fatalf("不正な登録が保存された")
	}

	// env 省略は production、トークンは小文字に正規化して保存する。
	if e := sendRegister(t, ws, &proto.RegisterPush{Provider: "apns-voip", Token: hex64}, 20); e != nil {
		t.Fatalf("正しい登録がエラー: %+v", e)
	}
	d, _ := fx.store.Device("dev-I")
	want := state.Push{Provider: "apns-voip", Token: strings.ToLower(hex64), Env: "production"}
	if d.Push == nil || *d.Push != want {
		t.Fatalf("保存内容 = %+v (%+v のはず)", d.Push, want)
	}
	// 同じ値 (大文字・明示 production) は変化なし → 間引きに掛からない。
	if e := sendRegister(t, ws, &proto.RegisterPush{Provider: "apns-voip", Token: hex64, Env: "production"}, 21); e != nil {
		t.Fatalf("同じ値の再登録がエラー: %+v", e)
	}
	// env だけの変更は変更として保存する。
	if e := sendRegister(t, ws, &proto.RegisterPush{Provider: "apns-voip", Token: hex64, Env: "development"}, 22); e != nil {
		t.Fatalf("env の変更がエラー: %+v", e)
	}
	if d, _ := fx.store.Device("dev-I"); d.Push == nil || d.Push.Env != "development" {
		t.Fatalf("env の変更が保存されない: %+v", d.Push)
	}
	// 続けての変更は 10 秒の間引きに掛かる (env の変更も変更として数える)。
	if e := sendRegister(t, ws, &proto.RegisterPush{Provider: "apns-voip", Token: hex64, Env: "production"}, 23); e == nil || e.Code != "rate_limited" {
		t.Fatalf("env の連続変更が間引かれない: %+v", e)
	}
}

// TestPushMixedProviders は同じ account の fcm 端末と apns-voip 端末の両方へ、
// provider と env 付きの送信先が渡ることを確認する。
func TestPushMixedProviders(t *testing.T) {
	rp := newRecordingPusher()
	fx := newFixtureWithPusher(t, rp)
	hex64 := strings.Repeat("c", 64)

	a := dial(t, fx.url, "dev-ANDROID")
	if _, ok := readJSON(t, a).(*proto.Hello); !ok {
		t.Fatalf("hello が来ない")
	}
	registerPush(t, a, "tok-fcm", 1)
	_ = a.Close(websocket.StatusNormalClosure, "")

	i := dial(t, fx.url, "dev-IOS")
	if _, ok := readJSON(t, i).(*proto.Hello); !ok {
		t.Fatalf("hello が来ない")
	}
	if e := sendRegister(t, i, &proto.RegisterPush{Provider: "apns-voip", Token: hex64, Env: "development"}, 2); e != nil {
		t.Fatalf("apns 登録がエラー: %+v", e)
	}
	_ = i.Close(websocket.StatusNormalClosure, "")
	waitSessions(t, fx, 0, 3*time.Second)

	fx.fb(t).InjectIncoming("102", "Bob", 0)
	c := rp.wait(t, 3*time.Second)
	got := map[string]push.Target{}
	for _, tg := range c.targets {
		got[tg.Token] = tg
	}
	if len(got) != 2 ||
		got["tok-fcm"] != (push.Target{Provider: "fcm", Token: "tok-fcm"}) ||
		got[hex64] != (push.Target{Provider: "apns-voip", Token: hex64, Env: "development"}) {
		t.Fatalf("送信先が不正: %+v", c.targets)
	}
}
