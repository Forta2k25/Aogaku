//
//  AppDelegate.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2025/08/04.
//

import UIKit
import FirebaseCore
import GoogleMobileAds
import FirebaseRemoteConfig   // ← 追加

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        FirebaseApp.configure()
        PushManager.shared.start()   // ← 追加
        
       
        // AdMob 初期化（Google Mobile Ads SDK v12+）
        MobileAds.shared.start { status in
            print("AdMob initialized: \(status.adapterStatusesByClassName)")
        }
        
        // ▼ 追加：Remote Config をフェッチして広告設定を有効化
        AdsSwitchboard.shared.start()
        
        // ✅ ここに追記（Remote Config で広告ID/ON-OFFを取得）
        //setupAdsRemoteConfig()

        // （任意）テストデバイス設定
        // v12 ではシミュレータ用の kGADSimulatorID は廃止。
        // 必要なら実機の Test Device ID を入れてください（ログに出ます）。
        #if DEBUG
        let reqConfig = MobileAds.shared.requestConfiguration
        reqConfig.testDeviceIdentifiers = []   // 例: ["xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]
        #endif
        // 任意：従来のフックを残す場合
        NotificationCenter.default.post(name: .adMobReady, object: nil)
        
        // Override point for customization after application launch.
        return true
    }

    
    // ← 追加（APNsトークン受け取り）
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs register failed:", error)
    }
    
    //通知ボタンの消去
    func applicationDidBecomeActive(_ application: UIApplication) {
        application.applicationIconBadgeNumber = 0
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }
    
    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        
    }

    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        _ = DeepLinkRouter.handle(url, window: UIApplication.shared.windows.first)
        return true
    }

}
extension Notification.Name {
    static let adMobReady = Notification.Name("AdMobReady")
}




