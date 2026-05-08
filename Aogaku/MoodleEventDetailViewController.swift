import UIKit
import SafariServices

private let detailGreen = UIColor(red: 0/255, green: 150/255, blue: 108/255, alpha: 1)

// MARK: - MoodleEventDetailViewController

final class MoodleEventDetailViewController: UIViewController {

    // MARK: Data
    let event: MoodleEvent
    private(set) var courseTitle: String?
    let pickerTitles: [String]
    var onCourseChanged: ((String) -> Void)?
    var onSubmittedChanged: (() -> Void)?

    // MARK: UI refs
    private let courseLbl   = UILabel()
    private let submitButton = UIButton(type: .system)

    // MARK: Init
    init(event: MoodleEvent, courseTitle: String?, pickerTitles: [String]) {
        self.event        = event
        self.courseTitle  = courseTitle
        self.pickerTitles = pickerTitles
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "課題の詳細"
        view.backgroundColor = .systemGroupedBackground
        buildNav()
        buildUI()
    }

    // MARK: - Nav
    private func buildNav() {
        let change = UIAction(title: "授業を変更",
                              image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.showPicker(from: nil)
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [change]))
    }

    // MARK: - Layout
    private func buildUI() {
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        let root = UIStackView()
        root.axis      = .vertical
        root.spacing   = 12
        root.layoutMargins = UIEdgeInsets(top: 20, left: 16, bottom: 32, right: 16)
        root.isLayoutMarginsRelativeArrangement = true
        root.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: scroll.topAnchor),
            root.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            root.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])

        // ① タイトルヘッダー（バッジ＋タイトル）
        root.addArrangedSubview(buildTitleHeader())

        // ② 情報カード（授業名 ＋ 期限）
        root.addArrangedSubview(buildInfoCard())

        // ③ 説明カード
        let desc = event.eventDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            root.addArrangedSubview(buildTextCard(body: desc))
        }

        // ④ URLカード
        let resolvedURL: URL? = event.eventURL.flatMap { URL(string: $0) }
            ?? firstURL(in: event.eventDescription)
        if let url = resolvedURL {
            root.addArrangedSubview(buildURLCard(url: url))
        }

        // ⑤ 提出済みボタン
        root.addArrangedSubview(buildSubmittedCard())
    }

    // ① タイトルヘッダー
    private func buildTitleHeader() -> UIView {
        // バッジ
        let badge = UILabel()
        badge.text      = "  \(typeLabel(event.eventType))  "
        badge.font      = .systemFont(ofSize: 11, weight: .semibold)
        let color: UIColor = event.isPast ? .systemGray : detailGreen
        badge.textColor = color
        badge.layer.borderColor  = color.cgColor
        badge.layer.borderWidth  = 1
        badge.layer.cornerRadius = 4
        badge.clipsToBounds      = true
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let badgeRow = UIStackView(arrangedSubviews: [badge, UIView()])
        badgeRow.axis    = .horizontal
        badgeRow.spacing = 0

        // タイトル
        let titleLbl = UILabel()
        titleLbl.text          = event.cleanTitle
        titleLbl.font          = .systemFont(ofSize: 22, weight: .bold)
        titleLbl.textColor     = event.isPast ? .secondaryLabel : detailGreen
        titleLbl.numberOfLines = 0

        let v = UIStackView(arrangedSubviews: [badgeRow, titleLbl])
        v.axis    = .vertical
        v.spacing = 8
        return v
    }

    // ② 情報カード
    private func buildInfoCard() -> UIView {
        // 授業名行
        courseLbl.font         = .systemFont(ofSize: 15)
        courseLbl.numberOfLines = 2
        refreshCourseLbl()

        let courseRow = makeRow(icon: "building.columns", label: courseLbl)
        // タップ（未設定なら選択）
        courseRow.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(courseTapped)))
        // 長押し（設定済みでも変更可能）
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(courseLongPressed(_:)))
        courseRow.addGestureRecognizer(lp)
        courseRow.isUserInteractionEnabled = true

        // 期限行
        let dateLbl = UILabel()
        dateLbl.font = .systemFont(ofSize: 15)
        if let d = event.dueDate {
            let df = DateFormatter()
            df.locale     = Locale(identifier: "ja_JP")
            df.dateFormat = "yyyy年M月d日(EEEE)  HH:mm"
            dateLbl.text      = df.string(from: d)
            dateLbl.textColor = event.isPast ? .secondaryLabel : .label
        } else {
            dateLbl.text      = "日時未設定"
            dateLbl.textColor = .tertiaryLabel
        }
        let dateRow = makeRow(icon: "calendar", label: dateLbl)

        let inner = UIStackView(arrangedSubviews: [courseRow, hairline(), dateRow])
        inner.axis    = .vertical
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false

        let card = cardView()
        card.addSubview(inner)
        pin(inner, to: card)
        return card
    }

    // ③ テキストカード（説明）
    private func buildTextCard(body: String) -> UIView {
        let lbl = UILabel()
        lbl.text          = body
        lbl.font          = .systemFont(ofSize: 14)
        lbl.textColor     = .secondaryLabel
        lbl.numberOfLines = 0
        lbl.translatesAutoresizingMaskIntoConstraints = false

        let card = cardView()
        card.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            lbl.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            lbl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])
        return card
    }

    // ④ URLカード
    private func buildURLCard(url: URL) -> UIView {
        let iconCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let icon    = UIImageView(image: UIImage(systemName: "arrow.up.right.square",
                                                 withConfiguration: iconCfg))
        icon.tintColor    = detailGreen
        icon.contentMode  = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let lbl = UILabel()
        lbl.text      = "提出先を開く"
        lbl.font      = .systemFont(ofSize: 15, weight: .medium)
        lbl.textColor = detailGreen

        let row = UIStackView(arrangedSubviews: [icon, lbl, UIView()])
        row.axis      = .horizontal
        row.spacing   = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false

        let card = cardView()
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])
        card.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                          action: #selector(urlTapped)))
        card.isUserInteractionEnabled = true
        card.tag = Int(url.absoluteString.hashValue & 0x7FFFFFFF)
        objc_setAssociatedObject(card, &AssocKey.url, url, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return card
    }

    // MARK: - View helpers

    private func makeRow(icon: String, label: UILabel) -> UIView {
        let img = UIImageView(image: UIImage(systemName: icon))
        img.tintColor    = .secondaryLabel
        img.contentMode  = .scaleAspectFit
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 20).isActive  = true
        img.heightAnchor.constraint(equalToConstant: 20).isActive = true
        img.setContentHuggingPriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false

        let h = UIStackView(arrangedSubviews: [img, label])
        h.axis      = .horizontal
        h.spacing   = 12
        h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            h.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            h.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            h.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        ])
        return container
    }

    private func cardView() -> UIView {
        let v = UIView()
        v.backgroundColor    = .secondarySystemGroupedBackground
        v.layer.cornerRadius = 12
        v.clipsToBounds      = true
        return v
    }

    private func hairline() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    private func pin(_ child: UIView, to parent: UIView) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        ])
    }

    private func refreshCourseLbl() {
        if let t = courseTitle {
            courseLbl.text      = t
            courseLbl.textColor = .label
        } else {
            courseLbl.text      = "授業を選択 ›"
            courseLbl.textColor = .systemOrange
        }
    }

    private func typeLabel(_ t: MoodleEventType) -> String {
        switch t {
        case .deadline: return "提出期限"
        case .start:    return "開始"
        case .end:      return "終了"
        case .other:    return "イベント"
        }
    }

    private func firstURL(in text: String) -> URL? {
        guard let det = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let m = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = m, let r = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[r]))
    }

    // MARK: - 提出済みカード

    private func buildSubmittedCard() -> UIView {
        applySubmitButtonStyle(isSubmitted: MoodleService.shared.isSubmitted(uid: event.uid))
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.translatesAutoresizingMaskIntoConstraints = false
        submitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        return submitButton
    }

    private func applySubmitButtonStyle(isSubmitted: Bool) {
        var cfg: UIButton.Configuration = isSubmitted ? .tinted() : .filled()
        cfg.title         = isSubmitted ? "提出済みを取り消す" : "提出済みにする"
        cfg.image         = UIImage(systemName: isSubmitted ? "arrow.uturn.backward" : "checkmark.circle.fill")
        cfg.imagePadding  = 8
        cfg.cornerStyle   = .large
        cfg.baseBackgroundColor = isSubmitted ? .systemOrange : detailGreen
        cfg.baseForegroundColor = isSubmitted ? .systemOrange : .white
        submitButton.configuration = cfg
    }

    @objc private func submitTapped() {
        let newState = MoodleService.shared.toggleSubmitted(uid: event.uid)
        applySubmitButtonStyle(isSubmitted: newState)
        NotificationCenter.default.post(name: .moodleSubmittedStateChanged, object: event.uid)
        onSubmittedChanged?()
    }

    // MARK: - Actions

    @objc private func courseTapped() {
        showPicker(from: nil)
    }

    @objc private func courseLongPressed(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        showPicker(from: gr.view)
    }

    @objc private func urlTapped(_ gr: UITapGestureRecognizer) {
        guard let url = objc_getAssociatedObject(gr.view as Any, &AssocKey.url) as? URL else { return }
        present(SFSafariViewController(url: url), animated: true)
    }

    // MARK: - Course Picker

    private func showPicker(from sourceView: UIView?) {
        guard !pickerTitles.isEmpty else { return }
        let sheet = UIAlertController(
            title: "授業を選択",
            message: "「\(event.cleanTitle)」はどの授業の課題ですか？",
            preferredStyle: .actionSheet)
        for title in pickerTitles {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                self.courseTitle = title
                MoodleService.shared.setManualCourse(
                    categoryCode: self.event.courseCode, title: title)
                self.refreshCourseLbl()
                self.onCourseChanged?(title)
            })
        }
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            if let sv = sourceView {
                pop.sourceView = sv
                pop.sourceRect = sv.bounds
            } else {
                pop.barButtonItem = navigationItem.rightBarButtonItem
            }
        }
        present(sheet, animated: true)
    }
}

// Associated object key for URL
private enum AssocKey {
    static var url = "MoodleEventDetailVC.url"
}
