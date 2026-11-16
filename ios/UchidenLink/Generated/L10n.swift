// 生成ファイル: 手で編集しない。正本は spec/strings.json、生成は ios/Tools/gen_spec.py。

import Foundation

/// 画面文言 (spec/strings.json)。キーは Android のリソース名を camelCase にしたもの。
enum L10n {
    static let appName = "ウチ電Link"
    static let commonOk = "OK"
    static let commonCancel = "キャンセル"
    static let commonClose = "閉じる"
    static let commonSave = "保存する"
    static let commonDelete = "削除する"
    static let commonAdd = "追加する"
    static let commonEdit = "編集"
    static let commonDeleteItem = "削除"
    static let commonUnset = "未設定"
    static let commonMicPermission = "マイク権限が必要です"
    static let groupUchi = "ウチ"
    static let groupSoto = "ソト"
    static let groupDevice = "端末"
    static let navKeypad = "キーパッド"
    static let navHistory = "履歴"
    static let navContacts = "連絡先"
    static let navSettings = "設定"
    static let callCaptionIncoming = "SIP BRIDGE・着信"
    static let callCaptionOutgoing = "SIP BRIDGE・発信"
    static let callCaptionIncall = "SIP BRIDGE・通話中"
    static let callUnknown = "不明な発信者"
    static func callStateIncoming(_ a1: String) -> String {
        String(format: "着信中 %1$@", a1)
    }
    static func callStateOutgoing(_ a1: String) -> String {
        String(format: "呼出中 %1$@", a1)
    }
    static func callStateOutgoingEarly(_ a1: String) -> String {
        String(format: "呼出中 (相手側応答音) %1$@", a1)
    }
    static func callEndToast(_ a1: String) -> String {
        String(format: "通話終了 %1$@", a1)
    }
    static let callAnswer = "応答"
    static let callReject = "拒否"
    static let callDisconnect = "切断"
    static let callMute = "ミュート"
    static let callKeypad = "キーパッド"
    static let callSpeaker = "スピーカー"
    static let callHold = "保留"
    static let callAdd = "通話を追加"
    static let callContacts = "連絡先"
    static let callEnd = "終了"
    static let callDeleteDesc = "削除 (長押しで全消去)"
    static let callDialDesc = "発信"
    static let keypadStatusOffline = "○ 未接続"
    static let keypadStatusUnregistered = "○ 未登録"
    static func keypadStatusRegistered(_ a1: String) -> String {
        String(format: "● 登録OK%1$@", a1)
    }
    static func keypadStatusExt(_ a1: String) -> String {
        String(format: "・内線 %1$@", a1)
    }
    static let keypadHintEmpty = "番号を入力、または履歴・連絡先から発信"
    static let keypadCaptionExtension = "内線番号"
    static let keypadCaptionExternal = "外線"
    static let keypadBackToCall = "通話に戻る"
    static let overlayCalling = "呼出中"
    static let keypadNeedNumber = "番号を入力してください"
    static let historyTitle = "履歴"
    static let historyClear = "全消去"
    static let historySegAll = "すべて"
    static let historySegMissed = "不在着信"
    static let historyEmpty = "履歴はまだありません"
    static let historyNote = "行をタップすると発信します。relay 経由のため端末では 5060 を待ち受けません。"
    static let historyMenuAdd = "連絡先に追加"
    static let historyClearMsg = "履歴をすべて削除しますか？"
    static let historyNeedName = "名前を入力してください"
    static let historyAdded = "連絡先に追加しました"
    static let historyUnknown = "不明"
    static let historyKindIn = "着信"
    static let historyKindOut = "発信"
    static let historyKindMissed = "不在着信"
    static let historyTimeYesterday = "昨日"
    static let historyNameHint = "名前"
    static let contactsTitle = "連絡先"
    static let contactsSearchHint = "🔍 名前・内線番号で検索"
    static let contactsEmpty = "連絡先を追加すると、着信時に名前で表示されます"
    static let contactsAddTitle = "連絡先を追加"
    static let contactsEditTitle = "連絡先を編集"
    static let contactsNeedBoth = "名前と番号を入力してください"
    static let contactsCall = "発信"
    static let contactsPickFromDevice = "端末の連絡先から選ぶ"
    static let contactsReadFail = "端末の連絡先を読み取れませんでした"
    static let contactsSaveToLocal = "連絡先に保存"
    static let contactsSaved = "連絡先に保存しました"
    static func contactsDeleteMsg(_ a1: String) -> String {
        String(format: "「%1$@」を削除しますか？", a1)
    }
    static let contactsNameHint = "名前"
    static let contactsNumberHint = "番号 (内線・外線)"
    static let settingsConnTitleOnline = "● relay に接続中"
    static let settingsConnTitleOffline = "○ 未接続"
    static let settingsConnTitleRetry = "再接続中…"
    static func settingsConnDetail(_ a1: String, _ a2: String) -> String {
        String(format: "%1$@・内線 %2$@", a1, a2)
    }
    static let settingsStatusInitial = "未起動"
    static let settingsConnStart = "開始"
    static let settingsConnStop = "停止"
    static let settingsSecConn = "接続"
    static let settingsSecSip = "SIP アカウント"
    static let settingsSecBehavior = "動作"
    static let settingsSecAudio = "音声"
    static let settingsSecPermission = "権限"
    static let settingsRowRelayUrl = "relay URL"
    static let settingsRowAccessId = "Access Client ID"
    static let settingsRowAccessSecret = "Access Secret"
    static let settingsRowDevToken = "Dev Token"
    static let settingsRowSipUser = "内線番号 (SIP user)"
    static let settingsRowSipPassword = "パスワード"
    static let settingsRowSipDisplay = "表示名 (任意)"
    static let settingsSipNote = "relay がこのアカウントで Asterisk に登録します。同じ内線を複数端末に設定すると同時着信し、先に応答した端末が通話します。"
    static let settingsSwSpeaker = "スピーカーで応答"
    static let settingsSwSpeakerDesc = "応答時にスピーカー出力にする (既定 OFF)。受話口の無い端末では OFF でもスピーカーになります"
    static let settingsSwDeviceContacts = "端末の連絡先を表示"
    static let settingsSwDeviceContactsDesc = "連絡先タブに「端末」グループを表示します (既定 OFF。ON にすると連絡先の権限を求めます)"
    static func settingsGain(_ a1: Double) -> String {
        String(format: "マイクゲイン: %1$.1f", a1)
    }
    static let settingsRowPermNotification = "通知"
    static let settingsRowPermMic = "マイク"
    static let settingsPermAllowed = "許可済み"
    static let settingsPermDenied = "未許可"
    static let settingsTestIncoming = "テスト着信を表示"
    static let settingsTestFrom = "テスト着信 (101)"
    static let settingsTestDisplay = "テスト"
    static func settingsFooter(_ a1: String, _ a2: String, _ a3: String) -> String {
        String(format: "アプリ版 %1$@ / relay 版 %2$@ / device %3$@", a1, a2, a3)
    }
    static let settingsConnNote = "relay URL は必須。認証は Cloudflare Access (Client ID + Secret) か Dev Token の**どちらか一方**で構いません。入力は欄を離れると自動保存されます。"
    static let settingsHintRelayUrl = "例: wss://relay.example.com"
    static let settingsHintDevToken = "Access を使わない開発・LAN 接続用"
    static func settingsSetupMissing(_ a1: String) -> String {
        String(format: "未入力: %1$@", a1)
    }
    static let settingsMissingRelayUrl = "relay URL"
    static let settingsMissingAuth = "認証 (Access Client ID + Secret か Dev Token)"
    static func settingsErrStartMissing(_ a1: String) -> String {
        String(format: "開始できません。%1$@ を入力してください", a1)
    }
    static let settingsErrUrlCleartextRelease = "平文の ws:// / http:// は使えません。wss:// で入力してください。保存していません"
    static let callEndedElsewhere = "他端末で応答"
    static let callEndedBye = "通話終了"
    static let callEndedCancel = "相手がキャンセル"
    static func callEndedReject(_ a1: Int) -> String {
        String(format: "拒否 (%1$ld)", a1)
    }
    static func callEndedTimeout(_ a1: Int) -> String {
        String(format: "無応答タイムアウト (%1$ld)", a1)
    }
    static func callEndedOther(_ a1: String, _ a2: Int) -> String {
        String(format: "終了 (%1$@ %2$ld)", a1, a2)
    }
    static let errorNoAccount = "SIP アカウント未設定のため発着信できません。設定タブで内線番号を入力してください"
    static let errorAccountPasswordMismatch = "内線のパスワードが relay の登録済み値と一致しません"
    static func errorAccountFailed(_ a1: String) -> String {
        String(format: "SIP アカウントの登録に失敗しました: %1$@", a1)
    }
    static func errorOther(_ a1: String, _ a2: String) -> String {
        String(format: "エラー (%1$@): %2$@", a1, a2)
    }
    static func outgoingFailedDial(_ a1: String) -> String {
        String(format: "発信できませんでした: %1$@", a1)
    }
    static let provisionScan = "QR コードで設定"
    static let provisionPaste = "貼り付けで設定"
    static let provisionScanPrompt = "設定用の QR コードを枠に合わせてください"
    static let provisionPasteTitle = "設定コードを貼り付け"
    static let provisionPasteHint = "{\"uchidenlink\":1,…}"
    static let provisionPasteOk = "読み込む"
    static let provisionErrorTitle = "読み込めませんでした"
    static let provisionConfirmTitle = "この内容で設定しますか?"
    static let provisionConfirmNote = "接続先が知らないホストなら設定しないでください (SIP パスワードがその接続先へ送られます)。書かれていない項目は今の設定のまま残ります。"
    static let provisionConfirmApply = "設定する"
    static func provisionLineRelay(_ a1: String) -> String {
        String(format: "接続先: %1$@", a1)
    }
    static func provisionLineAccess(_ a1: String) -> String {
        String(format: "Access Client ID: %1$@", a1)
    }
    static let provisionLineAccessSecret = "Access Secret: 含む"
    static let provisionLineDevToken = "Dev Token: 含む"
    static func provisionLineUser(_ a1: String) -> String {
        String(format: "内線番号: %1$@", a1)
    }
    static let provisionLinePassword = "SIP パスワード: 含む"
    static func provisionLineDisplay(_ a1: String) -> String {
        String(format: "表示名: %1$@", a1)
    }
    static func provisionLineMode(_ a1: String) -> String {
        String(format: "モード: %1$@", a1)
    }
    static let provisionLineCleared = "(空にする)"
    static let provisionApplied = "設定を読み込みました"
    static func provisionAppliedMissing(_ a1: String) -> String {
        String(format: "設定を読み込みました。%1$@ を入力してから開始してください", a1)
    }
    static let provisionNoCamera = "カメラが無いため QR コードを読めません。「貼り付けで設定」を使ってください"
    static let keypadModeForeground = "フォアグラウンド"
    static let settingsModeTitle = "接続方式"
    static let settingsModeDescForeground = "アプリを開いている間 WSS で接続します。閉じている間の着信は VoIP push で起こします (VoIP push は今後対応)。"
    static let settingsMissingSip = "SIP アカウント (内線番号)"
    static let settingsSecProvision = "設定コード"
    static let settingsSecTest = "テスト"
    static let settingsSecDebug = "デバッグ"
    static let settingsDebugMockUrl = "モック relay URL (ws://…、空なら通常接続)"
    static let settingsDebugLoopbackStart = "ループバック試験 (マイク→G.711→再生)"
    static let settingsDebugLoopbackStop = "ループバック試験を停止"
    static let settingsPermMicOpen = "設定アプリで許可"
    static let settingsRowDeviceId = "Device-Id"
    static let settingsSecretShow = "表示"
    static let settingsSecretHide = "隠す"
    static let settingsConnTitleConnecting = "接続中…"
    static let settingsConnTitleDisabled = "○ 停止中"
    static let callStateConnecting = "接続中…"
    static let callEndedLocal = "通話終了"
    static let callEndedFailed = "接続が切れたため通話を終了しました"
    static let callSpeakerFixed = "この端末はスピーカーのみ"
    static let callDtmfClose = "閉じる"
    static let contactsGroupLabel = "グループ"
    static let historySwipeDelete = "削除"
    static let keypadLongPressClear = "長押しで全消去"
}
