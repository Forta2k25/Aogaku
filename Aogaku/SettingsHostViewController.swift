// SettingsHostViewController.swift（←クラス名はあなたの既存名にしてOK）
import UIKit
import FirebaseAuth

/// 3つ目の「設定」タブの中身を、ログイン状態に応じて切り替えるホスト
final class SettingsHostViewController: UIViewController {

    private var current: UIViewController?
    private var authListener: AuthStateDidChangeListenerHandle?
    private let settingsTabIndex = 4   // 3つ目のタブ（0始まり）

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 初期表示
        swapContent(isLoggedIn: Auth.auth().currentUser != nil)

        // ログイン/ログアウトの変化を監視して自動切替
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            self.swapContent(isLoggedIn: user != nil)
            // ログイン直後は設定タブにフォーカス（不要なら消してOK）
            self.tabBarController?.selectedIndex = self.settingsTabIndex
        }
    }

    deinit {
        if let h = authListener { Auth.auth().removeStateDidChangeListener(h) }
    }

    private func swapContent(isLoggedIn: Bool) {
        // 既存の子VCを外す
        if let current {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        // 次に表示するVCを用意
        let next: UIViewController
        if isLoggedIn {
            // ★ログイン済み → 設定画面（Storyboard ID を UserSettingsViewController にしておく）
            let sb = UIStoryboard(name: "Main", bundle: nil)
            next = sb.instantiateViewController(withIdentifier: "UserSettingsViewController")
        } else {
            // ★未ログイン → 認証画面（コードで生成）
            next = AuthViewController()
        }

        // フルスクリーンで埋め込み
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        next.didMove(toParent: self)

        // 切替時はクロスディゾルブ
        if current != nil {
            UIView.transition(with: view, duration: 0.22, options: .transitionCrossDissolve, animations: nil)
        }
        current = next
    }
}
