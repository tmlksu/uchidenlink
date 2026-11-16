// Package push は push 送信の抽象化を行う。実送信は FCM (fcm.go) と
// APNs VoIP (apns.go) にあり、Multi (multi.go) が送信先ごとに振り分ける。
// 端末の push トークンの永続化は internal/state (Store) が担当する。
package push

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// provider 名 (register_push の provider、状態ファイルの push.provider)。
const (
	ProviderFCM      = "fcm"
	ProviderAPNsVoIP = "apns-voip"
)

// APNs の環境 (register_push の env、状態ファイルの push.env)。
const (
	EnvDevelopment = "development"
	EnvProduction  = "production"
)

// Payload は push で送る内容である。
type Payload struct {
	Type    string `json:"type"`
	CallID  string `json:"callId,omitempty"`
	From    string `json:"from,omitempty"`
	Display string `json:"display,omitempty"`
}

// Target は 1 端末分の送信先である。
//
//   - Provider は ProviderFCM / ProviderAPNsVoIP。空は ProviderFCM とみなす
//     (env 導入前の状態ファイル互換)。
//   - Env は APNs のみ意味を持つ (空は EnvProduction)。FCM では無視する。
type Target struct {
	Provider string
	Token    string
	Env      string
}

// Pusher は push 送信のインタフェースである。
// 送信先ごとに provider が異なってよい (Multi が振り分ける)。
type Pusher interface {
	Send(ctx context.Context, targets []Target, p Payload) error
}

// TokenRemover は無効になった push トークンの削除先である。
// internal/state.Store が実装する (RemoveToken)。
type TokenRemover interface {
	RemoveToken(token string) error
}

// Noop は何もしない Pusher (push 未設定時) である。
type Noop struct{}

// Send は常に nil を返す。
func (Noop) Send(_ context.Context, _ []Target, _ Payload) error { return nil }

// NormalizeRegistration は register_push の provider/token/env を検証・正規化する。
//
//   - provider は ProviderFCM か ProviderAPNsVoIP。それ以外はエラー。
//   - fcm: token は空でないこと。env は無視して "" にする。
//   - apns-voip: token は 16 進 (小文字に正規化) で長さ 64〜200。
//     env は "" (= production) / development / production。
//
// エラー文に token は含めない。
func NormalizeRegistration(provider, token, env string) (normToken, normEnv string, err error) {
	if token == "" {
		return "", "", errors.New("token が必要")
	}
	switch provider {
	case ProviderFCM:
		return token, "", nil
	case ProviderAPNsVoIP:
		if n := len(token); n < 64 || n > 200 {
			return "", "", fmt.Errorf("apns-voip の token の長さが不正 (%d。64〜200 の 16 進)", n)
		}
		for i := 0; i < len(token); i++ {
			c := token[i]
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return "", "", errors.New("apns-voip の token が 16 進ではない")
			}
		}
		switch env {
		case "":
			env = EnvProduction
		case EnvDevelopment, EnvProduction:
		default:
			return "", "", errors.New("env は development か production")
		}
		return strings.ToLower(token), env, nil
	case "":
		return "", "", errors.New("provider が必要")
	default:
		return "", "", errors.New("未知の provider (fcm か apns-voip)")
	}
}
