import UIKit

/// 授業ごとの「授業メモ」。ユーザー自身が書いて貯める(先生の特徴・テストの傾向・説明の好みなど)。端末の中にだけ保存する。
/// 授業(科目×年度×学期)ごとに分け、別の授業のメモは混ざらない。AIには毎回の質問に添えて渡す(資料ではなく、授業の背景として)。
enum AICourseMemoStore {
    static let maxCharacters = 1500
    private static func key(_ courseKey: String) -> String { "ai.courseMemo.\(courseKey)" }

    static func load(courseKey: String) -> String {
        UserDefaults.standard.string(forKey: key(courseKey)) ?? ""
    }
    static func save(_ text: String, courseKey: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters))
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: key(courseKey)) }
        else { UserDefaults.standard.set(trimmed, forKey: key(courseKey)) }
    }
}

/// 端末に保存済みのシラバス(`SyllabusDataCache`)を、AIに渡す短い要約にする。取れていない項目は出さない。
enum AISyllabusSummary {
    static func make(fields: [String: String]) -> String {
        func clip(_ text: String?, _ limit: Int) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: " / ").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let joined = lines.joined(separator: "\n")
            return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
        }
        var parts: [String] = []
        let head = [("科目", fields["__授業科目名"]), ("教員", fields["__教員名"]), ("単位", fields["__単位"]), ("学期", fields["__学期"]), ("年度", fields["__年度"])]
            .compactMap { label, value in clip(value, 80).map { "\(label): \($0)" } }
        if !head.isEmpty { parts.append(head.joined(separator: " / ")) }
        for (label, key, limit) in [("授業の概要", "__講義概要", 600), ("達成目標", "__達成目標", 500), ("履修条件", "__履修条件", 200),
                                    ("成績評価", "成績評価", 600), ("授業計画", "授業計画", 1500), ("教科書", "__教科書", 300)] {
            if let text = clip(fields[key], limit) { parts.append("【\(label)】\n\(text)") }
        }
        return String(parts.joined(separator: "\n").prefix(3500))
    }
}

/// 授業メモの編集画面。
final class CourseMemoViewController: UIViewController, UITextViewDelegate {
    private let courseKey: String
    private let courseTitle: String
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let counter = UILabel()

    init(courseKey: String, courseTitle: String) {
        self.courseKey = courseKey; self.courseTitle = courseTitle
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "授業メモ"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(save))

        let guide = UILabel()
        guide.numberOfLines = 0
        guide.font = .systemFont(ofSize: 13)
        guide.textColor = .secondaryLabel
        guide.text = "「\(courseTitle)」のAIが、毎回読みます。先生の特徴、テストの傾向、説明の好みなどを書いてください。端末の中にだけ保存され、他の授業には使われません。資料の内容より優先はされません。"
        guide.translatesAutoresizingMaskIntoConstraints = false

        textView.font = .systemFont(ofSize: 16)
        textView.text = AICourseMemoStore.load(courseKey: courseKey)
        textView.delegate = self
        textView.layer.cornerRadius = 10
        textView.layer.borderWidth = 0.5
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.accessibilityIdentifier = "course-memo-text"
        textView.translatesAutoresizingMaskIntoConstraints = false

        placeholder.text = "例: テストは配布プリントから出る。説明は、式変形を省かず、やさしく。"
        placeholder.numberOfLines = 0
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        counter.font = .systemFont(ofSize: 12)
        counter.textColor = .secondaryLabel
        counter.textAlignment = .right
        counter.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(guide); view.addSubview(textView); view.addSubview(counter); textView.addSubview(placeholder)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            guide.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            guide.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: guide.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -32),
            counter.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 6),
            counter.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
            placeholder.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -13)
        ])
        refresh()
    }

    func textViewDidChange(_ textView: UITextView) { refresh() }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let current = textView.text as NSString
        return current.replacingCharacters(in: range, with: text).count <= AICourseMemoStore.maxCharacters
    }
    private func refresh() {
        placeholder.isHidden = !textView.text.isEmpty
        counter.text = "\(textView.text.count) / \(AICourseMemoStore.maxCharacters)"
    }
    @objc private func cancel() { dismiss(animated: true) }
    @objc private func save() {
        AICourseMemoStore.save(textView.text, courseKey: courseKey)
        dismiss(animated: true)
    }
}
