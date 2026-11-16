// 生成ファイル: 手で編集しない。正本は spec/design-tokens.json、生成は ios/Tools/gen_spec.py。

import SwiftUI

/// Nocturne デザイントークン (UI-DESIGN.md §0)。
enum Nocturne {
    /// #0B0B11 — 画面背景
    static let bg = Color(red: 0.0431, green: 0.0431, blue: 0.0667)
    /// #14141C — カード / 入力欄 / タブバー
    static let surface = Color(red: 0.0784, green: 0.0784, blue: 0.1098)
    /// #1C1C27 — 押下・選択中のカード、キーパッドの丸ボタン
    static let surfaceHi = Color(red: 0.1098, green: 0.1098, blue: 0.1529)
    /// #262633 — カード枠線 / 区切り線
    static let border = Color(red: 0.1490, green: 0.1490, blue: 0.2000)
    /// #ECECF4 — 主文字
    static let text = Color(red: 0.9255, green: 0.9255, blue: 0.9569)
    /// #8B8BA0 — 補助文字 (番号・時刻・説明)
    static let textDim = Color(red: 0.5451, green: 0.5451, blue: 0.6275)
    /// #6B5FD6 — 応答/発信ボタン、選択タブ、状態ドット (登録OK)
    static let accent = Color(red: 0.4196, green: 0.3725, blue: 0.8392)
    /// #2A2652 — 選択中セグメントの背景、アバター円の塗り
    static let accentSoft = Color(red: 0.1647, green: 0.1490, blue: 0.3216)
    /// #C9C2FF — アバターの文字、アクセント上の薄い文字
    static let accentText = Color(red: 0.7882, green: 0.7608, blue: 1.0000)
    /// #2A2A36 — 拒否/終了/切断ボタン (赤は使わない)
    static let neutralBtn = Color(red: 0.1647, green: 0.1647, blue: 0.2118)
    /// #D98A8A — 不在着信の矢印/文字 (唯一の警告色)
    static let missed = Color(red: 0.8510, green: 0.5412, blue: 0.5412)

    enum Radius {
        static let card: CGFloat = 16
        static let input: CGFloat = 12
    }

    enum Size {
        static let keypadKey: CGFloat = 72
        static let callControl: CGFloat = 64
        static let callPrimary: CGFloat = 72
        static let dialButton: CGFloat = 72
        static let callAvatar: CGFloat = 96
        static let listAvatar: CGFloat = 40
        static let disabledAlpha: CGFloat = 0.35
    }

    enum Font {
        static let numberDisplay: CGFloat = 40
        static let keypadDigit: CGFloat = 28
        static let keypadLetters: CGFloat = 9
        static let callName: CGFloat = 28
        static let callNumber: CGFloat = 16
        static let callCaption: CGFloat = 11
        static let callLabel: CGFloat = 12
        static let pill: CGFloat = 17
    }
}
