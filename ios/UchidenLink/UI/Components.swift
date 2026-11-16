import UchidenLinkCore
import SwiftUI

// Nocturne の共通部品 (UI-DESIGN §0)。色・寸法は spec/design-tokens.json から生成した Nocturne を使う。

/// 角丸カード (surface + 1pt の border)。
struct NocturneCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Nocturne.surface, in: RoundedRectangle(cornerRadius: Nocturne.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Nocturne.Radius.card, style: .continuous).stroke(Nocturne.border, lineWidth: 1))
    }
}

/// カード内の区切り線。
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Nocturne.border).frame(height: 1)
    }
}

/// 名前の 1 文字目のアバター円 (accent_soft / accent_text)。
struct AvatarCircle: View {
    var name: String
    var size: CGFloat = Nocturne.Size.listAvatar

    var body: some View {
        Text(DisplayRules.avatarInitial(name))
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Nocturne.accentText)
            .frame(width: size, height: size)
            .background(Nocturne.accentSoft, in: Circle())
            .accessibilityHidden(true)
    }
}

/// 丸ボタン (通話操作・応答/終了・発信)。
struct RoundIconButton: View {
    var systemImage: String
    var fill: Color
    var foreground: Color = Nocturne.text
    var size: CGFloat
    var label: String? = nil
    var enabled = true
    var action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: size, height: size)
                    .background(fill, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(label ?? "")
            if let label {
                Text(label)
                    .font(.system(size: Nocturne.Font.callLabel))
                    .foregroundStyle(Nocturne.textDim)
            }
        }
        .opacity(enabled ? 1 : Nocturne.Size.disabledAlpha)
    }
}

/// キーパッドの状態ピル「● 登録OK・内線 2104」(UI-DESIGN §1.1)。
struct StatusPill: View {
    @EnvironmentObject private var manager: CallManager

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Nocturne.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Nocturne.surface, in: Capsule())
        .overlay(Capsule().stroke(Nocturne.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var dotColor: Color {
        if manager.conn != .connected { return Nocturne.border }
        return manager.registered ? Nocturne.accent : Nocturne.textDim
    }

    private var text: String {
        // 「● / ○」は色ドットで表すので文言からは外す
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: "● ", with: "").replacingOccurrences(of: "○ ", with: "")
        }
        if manager.conn != .connected { return strip(L10n.keypadStatusOffline) }
        if !manager.registered { return strip(L10n.keypadStatusUnregistered) }
        let ext = manager.account.isEmpty ? "" : L10n.keypadStatusExt(manager.account)
        return strip(L10n.keypadStatusRegistered(ext))
    }
}

/// 「通話に戻る」ピル (アプリ内。通話画面を閉じているときに右上へ出す。UI-DESIGN §3.2)。
struct BackToCallPill: View {
    @EnvironmentObject private var manager: CallManager
    var action: () -> Void

    var body: some View {
        if let ui = manager.callUI {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill")
                    switch ui.phase {
                    case .active(let since):
                        TimelineView(.periodic(from: since, by: 1)) { ctx in
                            Text(DisplayRules.duration(seconds: Int64(ctx.date.timeIntervalSince(since))))
                                .monospacedDigit()
                        }
                    case .ringingOut:
                        Text(L10n.overlayCalling)
                    default:
                        Text(L10n.keypadBackToCall)
                    }
                }
                .font(.system(size: Nocturne.Font.pill, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Nocturne.accent, in: Capsule())
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.keypadBackToCall)
        }
    }
}

/// 見出し (画面上部の大きめタイトル)。
struct ScreenTitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(Nocturne.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 通話終了のトースト (1.5 秒。UI-DESIGN §3.3)。
struct ToastView: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Nocturne.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Nocturne.surfaceHi, in: Capsule())
            .overlay(Capsule().stroke(Nocturne.border, lineWidth: 1))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
