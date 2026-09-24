//
//  DebugTextPreview.swift
//  Aogaku
//
//  開発用: 録音・撮影から検出されたテキストをその場で確認するためのビューア。
//  DEBUGビルドにのみ含まれ、Releaseには含まれない。
//

#if DEBUG
import UIKit
import ObjectiveC

private var debugRecognizedTextKey: UInt8 = 0

extension UIImageView {
    /// 開発用: このサムネイルに対応するOCR認識結果を一時的に保持する
    var debugRecognizedText: String? {
        get { objc_getAssociatedObject(self, &debugRecognizedTextKey) as? String }
        set { objc_setAssociatedObject(self, &debugRecognizedTextKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

enum DebugTextPreview {
    /// 検出テキストをフルスクリーンで表示する。「続ける」タップでcompletionを呼ぶ。
    static func present(on presenter: UIViewController, title: String, text: String, completion: (() -> Void)? = nil) {
        let contentVC = UIViewController()
        contentVC.title = title
        contentVC.view.backgroundColor = .systemBackground

        let badge = UILabel()
        badge.text = "開発用プレビュー(Releaseには表示されません)"
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .systemOrange
        badge.translatesAutoresizingMaskIntoConstraints = false

        let textView = UITextView()
        textView.text = text.isEmpty ? "(検出結果は空でした)" : text
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.translatesAutoresizingMaskIntoConstraints = false

        contentVC.view.addSubview(badge)
        contentVC.view.addSubview(textView)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: contentVC.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            badge.leadingAnchor.constraint(equalTo: contentVC.view.leadingAnchor, constant: 16),

            textView.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: contentVC.view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: contentVC.view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: contentVC.view.safeAreaLayoutGuide.bottomAnchor)
        ])

        let nav = UINavigationController(rootViewController: contentVC)
        contentVC.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "続ける",
            primaryAction: UIAction { _ in
                nav.dismiss(animated: true) { completion?() }
            }
        )
        presenter.present(nav, animated: true)
    }
}
#endif
