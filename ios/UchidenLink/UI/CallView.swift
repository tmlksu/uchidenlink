import UchidenLinkCore
import SwiftUI

/// 通話画面 (UI-DESIGN §2, §3)。情報は上、操作ボタンは下端寄せ。
/// iOS への適応: 左上の「∨」で画面を閉じてアプリに戻る (Android はホーム操作で離れる)。
/// アプリ外では CallKit の Dynamic Island / 緑のピルが通話中表示を担う。
struct CallView: View {
    @EnvironmentObject private var manager: CallManager
    var minimize: () -> Void
    @State private var showDtmf = false

    var body: some View {
        ZStack {
            background
            if let ui = manager.callUI {
                VStack(spacing: 0) {
                    topBar(ui)
                    Spacer(minLength: 24)
                    header(ui)
                    Spacer()
                    controls(ui)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDtmf) {
            DtmfSheet().environmentObject(manager)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var background: some View {
        ZStack {
            Nocturne.bg
            RadialGradient(colors: [Nocturne.accent.opacity(0.28), .clear], center: .init(x: 0.5, y: 0.18), startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }

    private func topBar(_ ui: CallUIState) -> some View {
        HStack {
            Button(action: minimize) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Nocturne.textDim)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.keypadBackToCall)
            Spacer()
            Text(caption(ui))
                .font(.system(size: Nocturne.Font.callCaption, weight: .medium))
                .kerning(1.6)
                .foregroundStyle(Nocturne.textDim)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func caption(_ ui: CallUIState) -> String {
        switch ui.phase {
        case .active: return L10n.callCaptionIncall
        case .ringingOut: return L10n.callCaptionOutgoing
        default: return L10n.callCaptionIncoming
        }
    }

    private func header(_ ui: CallUIState) -> some View {
        let name = ui.name.isEmpty ? (ui.number.isEmpty ? L10n.callUnknown : ui.number) : ui.name
        return VStack(spacing: 10) {
            AvatarCircle(name: name, size: Nocturne.Size.callAvatar)
            Text(name)
                .font(.system(size: Nocturne.Font.callName, weight: .medium))
                .foregroundStyle(Nocturne.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !ui.name.isEmpty, !ui.number.isEmpty {
                Text(ui.number)
                    .font(.system(size: Nocturne.Font.callNumber))
                    .foregroundStyle(Nocturne.textDim)
            }
            stateLine(ui)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func stateLine(_ ui: CallUIState) -> some View {
        switch ui.phase {
        case .active(let since):
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text(DisplayRules.duration(seconds: Int64(ctx.date.timeIntervalSince(since))))
                    .font(.system(size: 17).monospacedDigit())
                    .foregroundStyle(Nocturne.accentText)
            }
        case .ringingIn:
            AnimatedDots { L10n.callStateIncoming($0) }
        case .ringingOut(let early):
            AnimatedDots { early ? L10n.callStateOutgoingEarly($0) : L10n.callStateOutgoing($0) }
        case .connecting:
            Text(L10n.callStateConnecting).font(.system(size: 17)).foregroundStyle(Nocturne.textDim)
        }
    }

    @ViewBuilder
    private func controls(_ ui: CallUIState) -> some View {
        switch ui.phase {
        case .ringingIn, .connecting:
            HStack {
                RoundIconButton(systemImage: "phone.down.fill", fill: Nocturne.neutralBtn, size: Nocturne.Size.callPrimary, label: L10n.callReject) {
                    manager.endCurrentCallFromUI()
                }
                Spacer()
                RoundIconButton(systemImage: "phone.fill", fill: Nocturne.accent, foreground: .white, size: Nocturne.Size.callPrimary,
                                label: L10n.callAnswer, enabled: ui.phase == .ringingIn) {
                    manager.answerFromUI()
                }
            }
            .padding(.horizontal, 28)
        case .ringingOut:
            RoundIconButton(systemImage: "phone.down.fill", fill: Nocturne.neutralBtn, size: Nocturne.Size.callPrimary, label: L10n.callDisconnect) {
                manager.endCurrentCallFromUI()
            }
        case .active:
            VStack(spacing: 28) {
                let cols = Array(repeating: GridItem(.flexible()), count: 3)
                LazyVGrid(columns: cols, spacing: 22) {
                    toggle("mic.slash.fill", L10n.callMute, on: manager.isMuted) { manager.setMutedFromUI(!manager.isMuted) }
                    toggle("circle.grid.3x3.fill", L10n.callKeypad, on: false) { showDtmf = true }
                    toggle(manager.isSpeaker ? "speaker.wave.3.fill" : "speaker.wave.2.fill", L10n.callSpeaker, on: manager.isSpeaker,
                           enabled: manager.hasEarpiece) { manager.setSpeaker(!manager.isSpeaker) }
                    // v1 は無効 (保留は relay の re-INVITE 対応後)
                    toggle("pause.fill", L10n.callHold, on: false, enabled: false) {}
                    toggle("plus", L10n.callAdd, on: false, enabled: false) {}
                    toggle("person.crop.circle", L10n.callContacts, on: false, enabled: false) {}
                }
                RoundIconButton(systemImage: "phone.down.fill", fill: Nocturne.neutralBtn, size: Nocturne.Size.callPrimary, label: L10n.callEnd) {
                    manager.endCurrentCallFromUI()
                }
            }
        }
    }

    private func toggle(_ icon: String, _ label: String, on: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        RoundIconButton(systemImage: icon, fill: on ? Nocturne.accentSoft : Nocturne.surfaceHi,
                        foreground: on ? Nocturne.accentText : Nocturne.text,
                        size: Nocturne.Size.callControl, label: label, enabled: enabled, action: action)
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 「着信中 •••」の 3 点の点滅。
struct AnimatedDots: View {
    var text: (String) -> String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let n = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 3 + 1
            Text(text(String(repeating: "•", count: n) + String(repeating: " ", count: 3 - n)))
                .font(.system(size: 17))
                .foregroundStyle(Nocturne.textDim)
        }
    }
}

/// 通話中の DTMF キーパッド (in-band 120 ms。押下ごとに操作音 + 触覚)。
struct DtmfSheet: View {
    @EnvironmentObject private var manager: CallManager
    @Environment(\.dismiss) private var dismiss
    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(manager.dtmfDigits.isEmpty ? " " : manager.dtmfDigits)
                    .font(.system(size: 28, weight: .light).monospacedDigit())
                    .foregroundStyle(Nocturne.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button(L10n.callDtmfClose) { dismiss() }
                    .foregroundStyle(Nocturne.accentText)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 28) {
                    ForEach(row, id: \.self) { key in
                        KeypadKey(key: key, size: 60) { manager.sendDtmf(Character(key)) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Nocturne.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
