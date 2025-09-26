//
//  TextPageViewController.swift
//  Aogaku
//
//  Created by shu m on 2025/09/27.
//
import UIKit

/// タイトルと長文テキストをスクロール表示（全画面＋NavBar）
/// ・.txt / .md / .rtf をバンドルから読み込めます
final class TextPageViewController: UIViewController {

    private enum Body {
        case plain(String)
        case attributed(NSAttributedString)
    }

    private let titleText: String
    private let body: Body
    private let showsCloseButton: Bool

    // 読み取り専用テキストビュー（自動スクロール）
    private lazy var textView: UITextView = {
        let tv = UITextView(frame: .zero, textContainer: nil)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.showsVerticalScrollIndicator = true
        tv.backgroundColor = .clear
        tv.textColor = .label
        tv.font = .systemFont(ofSize: 16)
        tv.adjustsFontForContentSizeCategory = true
        tv.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 28, right: 20)
        tv.linkTextAttributes = [.foregroundColor: UIColor.link]
        return tv
    }()

    // 文字列で渡す通常版
    init(title: String, body: String, showsCloseButton: Bool = false) {
        self.titleText = title
        self.body = .plain(body)
        self.showsCloseButton = showsCloseButton
        super.init(nibName: nil, bundle: nil)
    }

    // ファイル名で渡す便利イニシャライザ（例: name="Terms", ext="txt"）
    convenience init(title: String, bundled name: String, ext: String = "txt", showsCloseButton: Bool = false) {
        let attr = TextPageViewController.readBundledText(name: name, ext: ext)
        self.init(title: title, attributed: attr, showsCloseButton: showsCloseButton)
    }

    // Attributed で渡したい場合
    init(title: String, attributed: NSAttributedString, showsCloseButton: Bool = false) {
        self.titleText = title
        self.body = .attributed(attributed)
        self.showsCloseButton = showsCloseButton
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.title = titleText
        if showsCloseButton {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "閉じる", style: .done, target: self, action: #selector(close)
            )
        }

        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        switch body {
        case .plain(let s):
            textView.text = s
        case .attributed(let a):
            textView.attributedText = a
        }
    }

    @objc private func close() { dismiss(animated: true) }

    // MARK: - Loader
    private static func readBundledText(name: String, ext: String) -> NSAttributedString {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            return NSAttributedString(string: "「\(name).\(ext)」が見つかりません。ターゲットに含めてください。")
        }
        do {
            let lower = ext.lowercased()
            if lower == "rtf" {
                let data = try Data(contentsOf: url)
                let att = try NSMutableAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
                normalizeColors(att)
                return att
            } else if lower == "rtfd" {
                // 画像入りの RTFD（パッケージ）も読みたい場合
                let att = try NSMutableAttributedString(
                    url: url,
                    options: [.documentType: NSAttributedString.DocumentType.rtfd],
                    documentAttributes: nil
                )
                normalizeColors(att)
                return att
            } else if lower == "md" {
                let str = try String(contentsOf: url, encoding: .utf8)
                if #available(iOS 15.0, *), let att = try? AttributedString(markdown: str) {
                    return NSAttributedString(att)
                }
                return NSAttributedString(string: str)
            } else { // txt など
                let str = try String(contentsOf: url, encoding: .utf8)
                return NSAttributedString(string: str)
            }
        } catch {
            return NSAttributedString(string: "読み込みに失敗しました：\(error.localizedDescription)")
        }
    }

    // RTF/RTFD が持つ固定テキスト色を除去して、UITextView の textColor(.label)に委ねる
    private static func normalizeColors(_ att: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: att.length)
        att.removeAttribute(.foregroundColor, range: full)
    }

}
