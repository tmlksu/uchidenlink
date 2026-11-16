import Intents
import SwiftUI
import UIKit

/// 起動処理は AppDelegate で行う: VoIP push でバックグラウンド起動されたときは SwiftUI のシーンが
/// 作られない (onAppear が来ない) が、PushKit の登録と CallKit の準備は起動直後に要るため。
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor lazy var manager = CallManager()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { manager.start() }
        return true
    }
}

@main
struct UchidenLinkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appDelegate.manager)
                .onChange(of: scenePhase) { _, phase in
                    appDelegate.manager.scenePhaseChanged(active: phase == .active)
                }
                .onContinueUserActivity("INStartCallIntent") { activity in
                    // 標準の履歴 (Recents) / Siri からの発信 (includesCallsInRecents=true, 設計 Q5)
                    if let intent = activity.interaction?.intent as? INStartCallIntent,
                       let person = intent.contacts?.first,
                       let number = person.personHandle?.value, !number.isEmpty {
                        appDelegate.manager.handleStartCallIntent(number: number)
                    }
                }
        }
    }
}
