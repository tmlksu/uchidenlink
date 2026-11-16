import UchidenLinkCore
import SwiftUI
import UIKit

/// キーパッド (UI-DESIGN §1.1)。キーと発信ボタンは画面下端寄せ (片手操作)。
struct KeypadView: View {
    @EnvironmentObject private var manager: CallManager
    @Binding var number: String
    var openSettings: () -> Void
    var openCall: () -> Void

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        GeometryReader { geo in
            let keySize = min(Nocturne.Size.keypadKey, (geo.size.height - 330) / 4.6, (geo.size.width - 96) / 3)
            VStack(spacing: 0) {
                HStack {
                    StatusPill()
                    Spacer()
                    Button(action: openSettings) {
                        Text(L10n.keypadModeForeground)
                            .font(.system(size: 13))
                            .foregroundStyle(Nocturne.accentText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Nocturne.accentSoft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                if !manager.lastError.isEmpty {
                    Text(manager.lastError)
                        .font(.system(size: 12))
                        .foregroundStyle(Nocturne.missed)
                        .lineLimit(2)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .onTapGesture { manager.lastError = "" }
                }
                Spacer(minLength: 8)
                numberDisplay
                VStack(spacing: keySize * 0.22) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: keySize * 0.42) {
                            ForEach(row, id: \.self) { key in
                                KeypadKey(key: key, size: keySize) { press(key) } longPress: {
                                    if key == "0" { append("+") }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 16)
                bottomRow(keySize: keySize)
                    .padding(.top, keySize * 0.3)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Nocturne.bg.ignoresSafeArea())
    }

    private var numberDisplay: some View {
        VStack(spacing: 6) {
            Text(number.isEmpty ? " " : number)
                .font(.system(size: Nocturne.Font.numberDisplay, weight: .light))
                .foregroundStyle(Nocturne.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 24)
                .contextMenu {
                    // iOS の作法: 長押しで番号を貼り付け
                    Button("ペースト", systemImage: "doc.on.clipboard") {
                        if let s = UIPasteboard.general.string {
                            number = String(s.filter { "0123456789*#+".contains($0) })
                        }
                    }
                }
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(Nocturne.textDim)
                .lineLimit(1)
        }
    }

    private var caption: String {
        switch DisplayRules.keypadCaption(number: number, contactName: manager.contacts.lookup(number)) {
        case .empty: return L10n.keypadHintEmpty
        case .contact(let name): return name
        case .extensionNumber: return L10n.keypadCaptionExtension
        case .external: return L10n.keypadCaptionExternal
        }
    }

    @ViewBuilder
    private func bottomRow(keySize: CGFloat) -> some View {
        HStack {
            Color.clear.frame(width: 56, height: 1)
            Spacer()
            if manager.callUI != nil {
                Button(action: openCall) {
                    Label(L10n.keypadBackToCall, systemImage: "phone.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: Nocturne.Size.dialButton * 0.75)
                        .background(Nocturne.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                RoundIconButton(systemImage: "phone.fill", fill: Nocturne.accent, foreground: .white,
                                size: min(Nocturne.Size.dialButton, keySize)) {
                    if number.isEmpty {
                        // 一般的な通話アプリと同じ: 空で押すと直前の発信番号を呼び戻す
                        if let last = manager.history.all().first(where: { $0.direction == .OUT }) {
                            number = last.number
                        } else {
                            manager.lastError = L10n.keypadNeedNumber
                        }
                        return
                    }
                    manager.startOutgoing(number: number)
                }
                .accessibilityLabel(L10n.callDialDesc)
            }
            Spacer()
            Button {
                if !number.isEmpty {
                    number.removeLast()
                    Haptics.tap()
                }
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 22))
                    .foregroundStyle(Nocturne.textDim)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .opacity(number.isEmpty ? 0 : 1)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                number = ""
                Haptics.longPress()
            })
            .accessibilityLabel(L10n.callDeleteDesc)
        }
        .padding(.horizontal, 36)
    }

    private func press(_ key: String) {
        append(key)
    }

    private func append(_ s: String) {
        guard number.count < 32 else { return }
        number += s
        manager.lastError = ""
    }
}

/// 丸キー (数字 28pt + 英字 9pt)。押下で軽い触覚 (端末の設定に従う)。
struct KeypadKey: View {
    var key: String
    var size: CGFloat
    var action: () -> Void
    var longPress: (() -> Void)? = nil
    /// 長押しが発火した直後の (指を離したときの) タップを捨てる
    @State private var suppressTap = false

    var body: some View {
        Button {
            if suppressTap {
                suppressTap = false
                return
            }
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 0) {
                Text(key)
                    .font(.system(size: Nocturne.Font.keypadDigit * min(1, size / Nocturne.Size.keypadKey)))
                    .foregroundStyle(Nocturne.text)
                if size >= 56, let letters = DisplayRules.keypadLetters[key], !letters.isEmpty {
                    Text(letters)
                        .font(.system(size: Nocturne.Font.keypadLetters, weight: .medium))
                        .kerning(1.5)
                        .foregroundStyle(Nocturne.textDim)
                }
            }
            .frame(width: size, height: size)
            .background(Nocturne.surfaceHi, in: Circle())
        }
        .buttonStyle(KeyPressStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            guard let longPress else { return }
            suppressTap = true
            Haptics.longPress()
            longPress()
        })
        .accessibilityLabel(key)
    }
}

struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.12 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// 触覚フィードバック。UIKit の generator は端末の「システムの触覚」設定が OFF なら鳴らない。
enum Haptics {
    @MainActor static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor static func longPress() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
