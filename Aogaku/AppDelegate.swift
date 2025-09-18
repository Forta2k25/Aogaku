//
//  AppDelegate.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2025/08/04.
//

import UIKit
import FirebaseCore
import GoogleMobileAds

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        FirebaseApp.configure()
        
        // AdMob 初期化（Google Mobile Ads SDK v12+）
        MobileAds.shared.start { status in
            print("AdMob initialized: \(status.adapterStatusesByClassName)")
        }

        // （任意）テストデバイス設定
        // v12 ではシミュレータ用の kGADSimulatorID は廃止。
        // 必要なら実機の Test Device ID を入れてください（ログに出ます）。
        #if DEBUG
        let reqConfig = MobileAds.shared.requestConfiguration
        reqConfig.testDeviceIdentifiers = []   // 例: ["xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]
        #endif
        
        // Override point for customization after application launch.
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
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

