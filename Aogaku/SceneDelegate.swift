//
//  SceneDelegate.swift
//  Aogaku
//
//  Created by 米沢怜生 on 2025/08/04.
//

import UIKit
import FirebaseAuth

class SceneDelegate: UIResponder, UIWindowSceneDelegate, UITabBarControllerDelegate {

    var window: UIWindow?


    // SceneDelegate.swift（該当メソッドだけ）
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: ws)
        let sb = UIStoryboard(name: "Main", bundle: nil)
        let root = sb.instantiateInitialViewController()
        if let tab = root as? UITabBarController {
            tab.delegate = self
            tab.selectedIndex = 0   // ← 初期は時間割タブ
            AppAnalytics.logTabView(tabName(for: tab, index: 0), index: 0)
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        AppAnalytics.logTabView(tabName(for: tabBarController, viewController: viewController),
                                index: tabBarController.selectedIndex)
    }
    
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.first?.url else { return }
        _ = DeepLinkRouter.handle(url, window: window)
    }


    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        let top = (window?.rootViewController?.presentedViewController)
                 ?? window?.rootViewController
        if let top { AppGatekeeper.shared.forceRefreshAndPresentIfNeeded(on: top) }
        FirstLaunchAlertService.maybeShow()
        BroadcastAlertService.maybeShow()     // ← ：全員に一度だけ（内容が変わるたび再表示）
    }
    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}

private extension SceneDelegate {
    func tabName(for tabBarController: UITabBarController, viewController: UIViewController) -> AppAnalytics.Tab {
        guard let index = tabBarController.viewControllers?.firstIndex(of: viewController) else {
            return .other
        }
        return tabName(for: tabBarController, index: index)
    }

    func tabName(for tabBarController: UITabBarController, index: Int) -> AppAnalytics.Tab {
        guard let viewControllers = tabBarController.viewControllers,
              viewControllers.indices.contains(index) else {
            return .other
        }

        let root = (viewControllers[index] as? UINavigationController)?.viewControllers.first
            ?? viewControllers[index]
        let title = root.title ?? viewControllers[index].tabBarItem.title ?? ""
        let typeName = String(describing: type(of: root))

        if typeName.contains("timetable") || typeName.contains("Timetable") || title.contains("時間割") {
            return .timetable
        }
        if typeName.contains("Syllabus") || title.contains("シラバス") {
            return .syllabus
        }
        if typeName.contains("Assignment") || typeName.contains("Moodle") || title.contains("課題") || title.contains("Moodle") {
            return .moodle
        }
        if typeName.contains("Circle") || title.contains("サークル") {
            return .circles
        }
        if typeName.contains("Friend") || title.contains("友") {
            return .friends
        }
        if typeName.contains("Settings") || title.contains("設定") {
            return .settings
        }
        return .other
    }
}
