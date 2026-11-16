package push

import (
	"context"
	"errors"
	"log/slog"
	"sync"
)

// Multi は送信先の provider ごとに送信器へ振り分ける Pusher である。
//
// 同じ account に Android (fcm) と iOS (apns-voip) の端末が混在してよい。
// provider ごとの送信は並行に行い、エラーは errors.Join でまとめる。
// 設定されていない provider (nil) や未知の provider 宛ての送信先は
// 送らずに捨て、Send 1 回につき provider ごとに 1 回だけ警告ログを出す
// (他の provider の送信は妨げない。エラーにも含めない)。
type Multi struct {
	// FCM は provider "fcm" (および空) の送信器。nil なら未設定。
	FCM Pusher
	// APNs は provider "apns-voip" の送信器。nil なら未設定。
	APNs Pusher
	// Log は警告ログの出力先。nil なら slog.Default()。
	Log *slog.Logger
}

// Send は送信先を provider ごとに分け、各送信器へ並行に渡す。
func (m *Multi) Send(ctx context.Context, targets []Target, p Payload) error {
	groups := make(map[string][]Target)
	for _, t := range targets {
		if t.Token == "" {
			continue
		}
		prov := t.Provider
		if prov == "" {
			prov = ProviderFCM
		}
		groups[prov] = append(groups[prov], t)
	}
	var (
		mu   sync.Mutex
		errs []error
		wg   sync.WaitGroup
	)
	for prov, ts := range groups {
		sender := m.senderFor(prov)
		if sender == nil {
			m.logger().Warn("push provider が未設定のため送信しない", "provider", prov, "devices", len(ts))
			continue
		}
		wg.Add(1)
		go func(sender Pusher, ts []Target) {
			defer wg.Done()
			if err := sender.Send(ctx, ts, p); err != nil {
				mu.Lock()
				errs = append(errs, err)
				mu.Unlock()
			}
		}(sender, ts)
	}
	wg.Wait()
	return errors.Join(errs...)
}

// senderFor は provider の送信器を返す (未設定・未知なら nil)。
func (m *Multi) senderFor(provider string) Pusher {
	var s Pusher
	switch provider {
	case ProviderFCM:
		s = m.FCM
	case ProviderAPNsVoIP:
		s = m.APNs
	}
	// 型付き nil (例: (*FCM)(nil)) を未設定として扱う。
	switch v := s.(type) {
	case *FCM:
		if v == nil {
			return nil
		}
	case *APNs:
		if v == nil {
			return nil
		}
	}
	return s
}

func (m *Multi) logger() *slog.Logger {
	if m.Log != nil {
		return m.Log
	}
	return slog.Default()
}
