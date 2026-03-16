import UIKit
import FirebaseFirestore

// MARK: - CircleDetail (file-private)

fileprivate struct CircleDetail: Hashable {
    let id: String

    var name: String
    var category: String?
    var tags: [String]

    var imageURLs: [String]
    var fallbackImageURL: String?

    var snsInstagram: String?
    var snsX: String?

    var activityPlace: String?
    var activitySchedule: String?
    var shortMessage: String?

    var memberSize: String?
    var genderRatio: String?
    var grade: String?

    // ✅ target (文字列で表示)
    var targetIntercollegiate: String?
    var targetNonFreshmen: String?
    var targetDoubleClub: String?

    // fee: { annualYen: Int, note: String }
    var annualYen: Int?
    var feeNote: String?

    // ratings: { activity: Int(1..5), vibe: Int(1..5) }
    var ratingActivity: Int?
    var ratingVibe: Int?

    var message: String?

    static func from(id: String, data: [String: Any]) -> CircleDetail {
        let imageURLs = data["imageURLs"] as? [String] ?? []
        let tags = data["tags"] as? [String] ?? []

        let sns = data["sns"] as? [String: Any]
        let activity = data["activity"] as? [String: Any]
        let members = data["members"] as? [String: Any]
        let fee = data["fee"] as? [String: Any]
        let ratings = data["ratings"] as? [String: Any]
        let target = data["target"] as? [String: Any]

        // ✅ Firestoreの数値が Int / String どちらでも拾えるようにする
        func intValue(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let s = any as? String { return Int(s) }
            return nil
        }

        return CircleDetail(
            id: id,
            name: data["name"] as? String ?? "",
            category: data["category"] as? String,
            tags: tags,

            imageURLs: imageURLs,
            fallbackImageURL: data["imageURL"] as? String,

            snsInstagram: sns?["instagram"] as? String,
            snsX: sns?["x"] as? String,

            activityPlace: activity?["place"] as? String,
            activitySchedule: activity?["schedule"] as? String,
            shortMessage: data["shortMessage"] as? String,

            memberSize: members?["size"] as? String,
            genderRatio: members?["genderRatio"] as? String,
            grade: members?["grade"] as? String,

            targetIntercollegiate: target?["intercollegiate"] as? String,
            targetNonFreshmen: target?["nonFreshmen"] as? String,
            targetDoubleClub: target?["doubleClub"] as? String,

            annualYen: fee?["annualYen"] as? Int,
            feeNote: fee?["note"] as? String,

            ratingActivity: intValue(ratings?["activity"]),
            ratingVibe: intValue(ratings?["vibe"]),

            message: data["message"] as? String
        )
    }
}

// MARK: - UI Components

fileprivate final class TagLabel: UILabel {
    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.text = text
        font = .systemFont(ofSize: 12, weight: .semibold)
        textColor = .white
        backgroundColor = .systemGreen
        layer.cornerRadius = 12
        layer.masksToBounds = true
        textAlignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 14, height: 24)
    }
}

fileprivate final class InfoCardView: UIView {
    enum Style {
        case filled(background: UIColor)
        case outlined(border: UIColor)
    }

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    init(title: String,
         value: String?,
         style: Style,
         fixedHeight: CGFloat,
         valueFont: UIFont,
         valueNumberOfLines: Int,
         shrinkToFit: Bool,
         centerValue: Bool) {

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        layer.cornerRadius = 14
        clipsToBounds = true

        switch style {
        case .filled(let bg):
            backgroundColor = bg
            layer.borderWidth = 0
        case .outlined(let border):
            backgroundColor = .clear
            layer.borderWidth = 1
            layer.borderColor = border.cgColor
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabel

        valueLabel.text = (value?.isEmpty == false) ? value : "—"
        valueLabel.font = valueFont
        valueLabel.numberOfLines = valueNumberOfLines
        valueLabel.textColor = UIColor { trait in
            if trait.userInterfaceStyle == .dark { return .label }
            return UIColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1) // #333333
        }
        valueLabel.lineBreakMode = .byTruncatingTail

        if shrinkToFit {
            valueLabel.adjustsFontSizeToFitWidth = true
            valueLabel.minimumScaleFactor = 0.75
            valueLabel.baselineAdjustment = .alignCenters
        }

        addSubview(titleLabel)
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: fixedHeight),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        if centerValue {
            NSLayoutConstraint.activate([
                valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 8),
                valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
                valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
            ])
        } else {
            NSLayoutConstraint.activate([
                valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
                valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                valueLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: String?) {
        let t = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        valueLabel.text = t.isEmpty ? "—" : t
    }
}

/// ✅ 費用の行（灰色角丸／高さ短め／中央に値／文字小さめ）
fileprivate final class FeeRowView: UIView {
    private let leftLabel = UILabel()
    private let centerLabel = UILabel()

    init(leftText: String, bg: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = bg
        layer.cornerRadius = 14
        clipsToBounds = true

        leftLabel.translatesAutoresizingMaskIntoConstraints = false
        leftLabel.text = leftText
        leftLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        leftLabel.textColor = .secondaryLabel

        centerLabel.translatesAutoresizingMaskIntoConstraints = false
        centerLabel.text = "—"
        // ✅ 文字を小さく
        centerLabel.font = .systemFont(ofSize: 16, weight: .bold)
        centerLabel.textAlignment = .center
        centerLabel.textColor = UIColor { trait in
            if trait.userInterfaceStyle == .dark { return .label }
            return UIColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1)
        }
        centerLabel.numberOfLines = 1
        centerLabel.adjustsFontSizeToFitWidth = true
        centerLabel.minimumScaleFactor = 0.8

        addSubview(leftLabel)
        addSubview(centerLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52), // ✅ 背景を縦に短く

            leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            leftLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            centerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leftLabel.trailingAnchor, constant: 10),
            centerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setValue(_ text: String?) {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        centerLabel.text = t.isEmpty ? "—" : t
    }
}

/// 5段階評価（灰色カード）
fileprivate final class RatingScaleView: UIView {
    private let titleLabel = UILabel()
    private let leftLabel = UILabel()
    private let rightLabel = UILabel()
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []

    init(title: String, leftText: String, rightText: String, bg: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = bg
        layer.cornerRadius = 14
        clipsToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .label

        leftLabel.translatesAutoresizingMaskIntoConstraints = false
        leftLabel.text = leftText
        leftLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        leftLabel.textColor = .label

        rightLabel.translatesAutoresizingMaskIntoConstraints = false
        rightLabel.text = rightText
        rightLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        rightLabel.textColor = .label
        rightLabel.textAlignment = .right

        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.axis = .horizontal
        dotsStack.alignment = .center
        dotsStack.spacing = 10
        dotsStack.distribution = .equalCentering

        for _ in 0..<5 {
            let v = UIView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.layer.cornerRadius = 11
            v.layer.borderWidth = 3
            v.layer.borderColor = UIColor.systemGray3.cgColor
            v.backgroundColor = .clear
            NSLayoutConstraint.activate([
                v.widthAnchor.constraint(equalToConstant: 22),
                v.heightAnchor.constraint(equalToConstant: 22)
            ])
            dotViews.append(v)
            dotsStack.addArrangedSubview(v)
        }

        let row = UIStackView(arrangedSubviews: [leftLabel, dotsStack, rightLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12

        leftLabel.setContentHuggingPriority(.required, for: .horizontal)
        rightLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 92),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            row.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setScore(_ score: Int?) {
        guard let score else {
            // nilなら全部未選択
            for v in dotViews {
                v.layer.borderColor = UIColor.systemGray3.cgColor
                v.backgroundColor = .clear
            }
            return
        }

        let s = max(1, min(score, 5))

        for (i, v) in dotViews.enumerated() {
            let isSelected = (i == s - 1)

            if isSelected {
                v.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.6).cgColor
                v.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.22) // ← 薄緑
            } else {
                v.layer.borderColor = UIColor.systemGray3.cgColor
                v.backgroundColor = .clear
            }
        }
    }
}

// MARK: - ViewController

final class CircleDetailViewController: UIViewController, UIScrollViewDelegate {

    private let circleId: String
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var detail: CircleDetail?

    private static let bookmarkDidChangeName = Notification.Name("bookmarkDidChange")

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private var didIncrementPopularity = false

    // Header
    private let headerScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.isPagingEnabled = true
        sv.showsHorizontalScrollIndicator = false
        sv.backgroundColor = .tertiarySystemFill
        return sv
    }()

    private let headerImagesStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 0
        return st
    }()

    private let pageControl: UIPageControl = {
        let pc = UIPageControl()
        pc.translatesAutoresizingMaskIntoConstraints = false
        pc.hidesForSinglePage = true
        return pc
    }()

    // Title area
    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = .systemFont(ofSize: 26, weight: .bold)
        lb.textColor = .label
        lb.numberOfLines = 2
        return lb
    }()

    private let bookmarkButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.backgroundColor = .systemBackground
        btn.layer.cornerRadius = 12
        btn.clipsToBounds = true
        btn.layer.borderWidth = 1
        btn.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.45).cgColor
        btn.tintColor = .systemGreen
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        btn.setImage(UIImage(systemName: "bookmark"), for: .normal)
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 34),
            btn.heightAnchor.constraint(equalToConstant: 34)
        ])
        return btn
    }()

    private let categoryLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = .systemFont(ofSize: 14, weight: .semibold)
        lb.textColor = .secondaryLabel
        lb.numberOfLines = 2
        return lb
    }()

    private let tagsStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .center
        return st
    }()

    // SNS (right aligned)
    private let nameAndSnsRow = UIStackView()
    private let snsInlineStack = UIStackView()
    private let titleSnsSpacer = UIView()
    private var instagramButton: UIButton!
    private var xButton: UIButton!

    // Top cards
    private let grid1 = UIStackView()
    private let shortMessageLabel = UILabel()

    // references
    private var cardPlace: InfoCardView!
    private var cardSchedule: InfoCardView!

    // ✅ Order sections
    private let memberSectionTitle = UILabel()
    private let memberRow = UIStackView()
    private var cardSize: InfoCardView!
    private var cardGender: InfoCardView!
    private var cardGrade: InfoCardView!

    private let targetSectionTitle = UILabel()
    private let targetRow = UIStackView()
    private var cardIntercollegiate: InfoCardView!
    private var cardNonFreshmen: InfoCardView!
    private var cardDoubleClub: InfoCardView!

    // Ratings
    private let ratingStack = UIStackView()
    private var ratingActivityView: RatingScaleView!
    private var ratingVibeView: RatingScaleView!

    // Message
    private let messageTitle = UILabel()
    private let messageBody = UILabel()

    // Fee section
    private let feeTitleLabel = UILabel()
    private let feeSectionStack = UIStackView()
    private var feeRowAnnual: FeeRowView!
    private var feeRowOther: FeeRowView!

    // CTA centered
    private let instagramCTAButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setTitle("Instagramから新歓情報を確認", for: .normal)
        b.setTitleColor(.systemGreen, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        b.contentHorizontalAlignment = .center // ✅ 真ん中
        return b
    }()

    // MARK: - Init

    init(circleId: String) {
        self.circleId = circleId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        buildUI()
        startListening()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(bookmarkDidChange),
                                               name: Self.bookmarkDidChangeName,
                                               object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateBookmarkButtonUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        listener?.remove()
    }

    // MARK: - UI helpers

    private func grayBG() -> UIColor {
        UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return .secondarySystemGroupedBackground
            }
            return UIColor(red: 246/255, green: 247/255, blue: 247/255, alpha: 1) // #F6F7F7
        }
    }

    private func setLineSpacing(_ label: UILabel, text: String?, spacing: CGFloat = 3.0) {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            label.text = "—"
            label.attributedText = nil
            return
        }
        let p = NSMutableParagraphStyle()
        p.lineSpacing = spacing
        p.lineBreakMode = label.lineBreakMode
        p.alignment = label.textAlignment
        label.attributedText = NSAttributedString(
            string: t,
            attributes: [
                .font: label.font as Any,
                .foregroundColor: label.textColor as Any,
                .paragraphStyle: p
            ]
        )
    }

    // MARK: - Build UI

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        // Header
        contentView.addSubview(headerScrollView)
        headerScrollView.addSubview(headerImagesStack)
        contentView.addSubview(pageControl)

        headerScrollView.delegate = self

        NSLayoutConstraint.activate([
            headerScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerScrollView.heightAnchor.constraint(equalToConstant: 240),

            headerImagesStack.topAnchor.constraint(equalTo: headerScrollView.contentLayoutGuide.topAnchor),
            headerImagesStack.bottomAnchor.constraint(equalTo: headerScrollView.contentLayoutGuide.bottomAnchor),
            headerImagesStack.leadingAnchor.constraint(equalTo: headerScrollView.contentLayoutGuide.leadingAnchor),
            headerImagesStack.trailingAnchor.constraint(equalTo: headerScrollView.contentLayoutGuide.trailingAnchor),
            headerImagesStack.heightAnchor.constraint(equalTo: headerScrollView.frameLayoutGuide.heightAnchor),

            pageControl.bottomAnchor.constraint(equalTo: headerScrollView.bottomAnchor, constant: -10),
            pageControl.centerXAnchor.constraint(equalTo: headerScrollView.centerXAnchor)
        ])

        // Bookmark
        bookmarkButton.addTarget(self, action: #selector(didTapBookmark), for: .touchUpInside)

        // SNS buttons
        instagramButton = makeSNSButton(assetName: "instagram",
                                        renderingMode: .alwaysOriginal,
                                        imageInsets: UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6),
                                        fallbackSystemName: "camera",
                                        action: #selector(tapInstagram))

        xButton = makeSNSButton(assetName: "X",
                                renderingMode: .alwaysTemplate,
                                imageInsets: UIEdgeInsets(top: 9, left: 9, bottom: 9, right: 9),
                                fallbackSystemName: "xmark",
                                action: #selector(tapX))

        snsInlineStack.translatesAutoresizingMaskIntoConstraints = false
        snsInlineStack.axis = .horizontal
        snsInlineStack.alignment = .center
        snsInlineStack.spacing = 10
        snsInlineStack.addArrangedSubview(instagramButton)
        snsInlineStack.addArrangedSubview(xButton)

        // ✅ 団体名 + SNS（SNSは右寄せ）
        titleSnsSpacer.translatesAutoresizingMaskIntoConstraints = false

        nameAndSnsRow.translatesAutoresizingMaskIntoConstraints = false
        nameAndSnsRow.axis = .horizontal
        nameAndSnsRow.alignment = .center
        nameAndSnsRow.spacing = 10
        nameAndSnsRow.addArrangedSubview(titleLabel)
        nameAndSnsRow.addArrangedSubview(titleSnsSpacer)
        nameAndSnsRow.addArrangedSubview(snsInlineStack)

        titleSnsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleSnsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snsInlineStack.setContentHuggingPriority(.required, for: .horizontal)

        let titleBlock = UIStackView(arrangedSubviews: [
            bookmarkButton,
            nameAndSnsRow,
            categoryLabel,
            tagsStack
        ])
        titleBlock.translatesAutoresizingMaskIntoConstraints = false
        titleBlock.axis = .vertical
        titleBlock.spacing = 14
        titleBlock.alignment = .leading

        contentView.addSubview(titleBlock)

        NSLayoutConstraint.activate([
            titleBlock.topAnchor.constraint(equalTo: headerScrollView.bottomAnchor, constant: 18),
            titleBlock.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            titleBlock.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18)
        ])

        // 活動場所 / 活動日時（この後の順序には入れないが、上部の情報として残す）
        cardPlace = InfoCardView(title: "活動場所", value: nil,
                                 style: .filled(background: grayBG()),
                                 fixedHeight: 62,
                                 valueFont: .systemFont(ofSize: 15, weight: .semibold),
                                 valueNumberOfLines: 2,
                                 shrinkToFit: false,
                                 centerValue: false)

        cardSchedule = InfoCardView(title: "活動日時", value: nil,
                                    style: .filled(background: grayBG()),
                                    fixedHeight: 62,
                                    valueFont: .systemFont(ofSize: 15, weight: .semibold),
                                    valueNumberOfLines: 2,
                                    shrinkToFit: false,
                                    centerValue: false)

        grid1.axis = .horizontal
        grid1.spacing = 14
        grid1.distribution = .fillEqually
        grid1.translatesAutoresizingMaskIntoConstraints = false
        grid1.addArrangedSubview(cardPlace)
        grid1.addArrangedSubview(cardSchedule)

        shortMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        shortMessageLabel.font = .systemFont(ofSize: 15, weight: .bold)
        shortMessageLabel.textColor = UIColor { trait in
            if trait.userInterfaceStyle == .dark { return .label }
            return UIColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1)
        }
        shortMessageLabel.numberOfLines = 0
        shortMessageLabel.isHidden = true

        // Borders
        let border = UIColor(red: 234/255, green: 234/255, blue: 234/255, alpha: 1) // #EAEAEA

        // ✅ 1) メンバー構成
        memberSectionTitle.translatesAutoresizingMaskIntoConstraints = false
        memberSectionTitle.text = "メンバー構成"
        memberSectionTitle.font = .systemFont(ofSize: 20, weight: .bold)

        cardSize = InfoCardView(title: "人数", value: nil,
                                style: .outlined(border: border),
                                fixedHeight: 88,
                                valueFont: .systemFont(ofSize: 16, weight: .bold),
                                valueNumberOfLines: 1,
                                shrinkToFit: true,
                                centerValue: true)

        cardGender = InfoCardView(title: "男女比", value: nil,
                                  style: .outlined(border: border),
                                  fixedHeight: 88,
                                  valueFont: .systemFont(ofSize: 16, weight: .bold),
                                  valueNumberOfLines: 1,
                                  shrinkToFit: true,
                                  centerValue: true)

        cardGrade = InfoCardView(title: "学年", value: nil,
                                 style: .outlined(border: border),
                                 fixedHeight: 88,
                                 valueFont: .systemFont(ofSize: 16, weight: .bold),
                                 valueNumberOfLines: 1,
                                 shrinkToFit: true,
                                 centerValue: true)

        memberRow.axis = .horizontal
        memberRow.spacing = 14
        memberRow.distribution = .fillEqually
        memberRow.translatesAutoresizingMaskIntoConstraints = false
        memberRow.addArrangedSubview(cardSize)
        memberRow.addArrangedSubview(cardGender)
        memberRow.addArrangedSubview(cardGrade)

        // ✅ 2) 対象
        targetSectionTitle.translatesAutoresizingMaskIntoConstraints = false
        targetSectionTitle.text = "対象"
        targetSectionTitle.font = .systemFont(ofSize: 20, weight: .bold)

        cardIntercollegiate = InfoCardView(title: "インカレ", value: nil,
                                           style: .outlined(border: border),
                                           fixedHeight: 88,
                                           valueFont: .systemFont(ofSize: 14, weight: .bold),
                                           valueNumberOfLines: 2,
                                           shrinkToFit: true,
                                           centerValue: true)

        cardNonFreshmen = InfoCardView(title: "新入生以外", value: nil,
                                       style: .outlined(border: border),
                                       fixedHeight: 88,
                                       valueFont: .systemFont(ofSize: 14, weight: .bold),
                                       valueNumberOfLines: 2,
                                       shrinkToFit: true,
                                       centerValue: true)

        cardDoubleClub = InfoCardView(title: "兼サー", value: nil,
                                      style: .outlined(border: border),
                                      fixedHeight: 88,
                                      valueFont: .systemFont(ofSize: 14, weight: .bold),
                                      valueNumberOfLines: 2,
                                      shrinkToFit: true,
                                      centerValue: true)

        targetRow.axis = .horizontal
        targetRow.spacing = 14
        targetRow.distribution = .fillEqually
        targetRow.translatesAutoresizingMaskIntoConstraints = false
        targetRow.addArrangedSubview(cardIntercollegiate)
        targetRow.addArrangedSubview(cardNonFreshmen)
        targetRow.addArrangedSubview(cardDoubleClub)

        // ✅ 3) 活動 / 雰囲気
        ratingActivityView = RatingScaleView(title: "活動", leftText: "ゆるめ", rightText: "本気で", bg: .clear)
        ratingVibeView     = RatingScaleView(title: "雰囲気", leftText: "静かめ", rightText: "賑やか", bg: .clear)

        ratingStack.translatesAutoresizingMaskIntoConstraints = false
        ratingStack.axis = .vertical
        ratingStack.spacing = 14
        ratingStack.addArrangedSubview(ratingActivityView)
        ratingStack.addArrangedSubview(ratingVibeView)

        // ✅ 4) 団体からのメッセージ
        messageTitle.translatesAutoresizingMaskIntoConstraints = false
        messageTitle.text = "団体からのメッセージ"
        messageTitle.font = .systemFont(ofSize: 18, weight: .bold)

        messageBody.translatesAutoresizingMaskIntoConstraints = false
        messageBody.font = .systemFont(ofSize: 14, weight: .regular)
        messageBody.textColor = .label
        messageBody.numberOfLines = 0

        // ✅ 5) 費用について
        feeTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        feeTitleLabel.text = "費用について"
        feeTitleLabel.font = .systemFont(ofSize: 18, weight: .bold)

        feeRowAnnual = FeeRowView(leftText: "費用", bg: grayBG())
        feeRowOther = FeeRowView(leftText: "その他費用", bg: grayBG())

        feeSectionStack.translatesAutoresizingMaskIntoConstraints = false
        feeSectionStack.axis = .vertical
        feeSectionStack.spacing = 12
        feeSectionStack.addArrangedSubview(feeTitleLabel)
        feeSectionStack.addArrangedSubview(feeRowAnnual)
        feeSectionStack.addArrangedSubview(feeRowOther)

        // CTA
        instagramCTAButton.addTarget(self, action: #selector(tapInstagramCTA), for: .touchUpInside)

        // ✅ Root order:
        let root = UIStackView(arrangedSubviews: [
            shortMessageLabel,

            grid1,

            ratingStack,

            targetSectionTitle,
            targetRow,

            memberSectionTitle,
            memberRow,

            feeSectionStack,

            messageTitle,
            messageBody,

            instagramCTAButton
        ])
        root.translatesAutoresizingMaskIntoConstraints = false
        root.axis = .vertical
        root.spacing = 14

        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: titleBlock.bottomAnchor, constant: 22),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28)
        ])
    }

    // MARK: - Header paging

    private func makeHeaderImageView() -> UIImageView {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .tertiarySystemFill
        return iv
    }

    private func reloadHeaderImages(with urls: [String]) {
        headerImagesStack.arrangedSubviews.forEach { v in
            headerImagesStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let valid = urls.filter { !$0.isEmpty }
        pageControl.numberOfPages = max(valid.count, 1)
        pageControl.currentPage = 0

        let useURLs = valid.isEmpty ? [detail?.fallbackImageURL].compactMap { $0 } : valid
        let finalURLs = useURLs.isEmpty ? [""] : useURLs

        for url in finalURLs {
            let iv = makeHeaderImageView()
            headerImagesStack.addArrangedSubview(iv)
            NSLayoutConstraint.activate([
                iv.widthAnchor.constraint(equalTo: headerScrollView.frameLayoutGuide.widthAnchor),
                iv.heightAnchor.constraint(equalTo: headerScrollView.frameLayoutGuide.heightAnchor)
            ])

            if !url.isEmpty {
                loadImage(from: url, into: iv)
            } else {
                iv.image = UIImage(systemName: "photo")
                iv.tintColor = .secondaryLabel
                iv.contentMode = .scaleAspectFit
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView == headerScrollView else { return }
        let w = scrollView.frame.width
        if w > 0 {
            let page = Int((scrollView.contentOffset.x + w / 2) / w)
            pageControl.currentPage = max(0, min(page, pageControl.numberOfPages - 1))
        }
    }

    // MARK: - Firestore

    private func startListening() {
        listener?.remove()
        listener = db.collection("circle").document(circleId)
            .addSnapshotListener { [weak self] snap, err in
                guard let self = self else { return }
                if let err = err {
                    print("CircleDetail listen error:", err)
                    return
                }
                guard let snap = snap, let data = snap.data() else { return }

                let d = CircleDetail.from(id: snap.documentID, data: data)
                self.detail = d

                self.reloadHeaderImages(with: d.imageURLs)
                self.applyDetail(d)

                if self.didIncrementPopularity == false {
                    self.didIncrementPopularity = true
                    self.incrementPopularityOnce()
                }
            }
    }

    private func incrementPopularityOnce() {
        let ref = db.collection("circle").document(circleId)
        ref.updateData(["popularity": FieldValue.increment(Int64(1))]) { err in
            if let err = err { print("popularity increment error:", err) }
        }
    }

    // MARK: - Apply

    private func applyDetail(_ d: CircleDetail) {
        updateBookmarkButtonUI()

        titleLabel.text = d.name

        if let cat = d.category, !cat.isEmpty {
            categoryLabel.text = cat
            categoryLabel.isHidden = false
        } else {
            categoryLabel.text = nil
            categoryLabel.isHidden = true
        }

        // tags
        tagsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if d.tags.isEmpty {
            tagsStack.isHidden = true
        } else {
            tagsStack.isHidden = false
            d.tags.prefix(4).forEach { tag in
                tagsStack.addArrangedSubview(TagLabel(text: tag))
            }
        }

        // sns
        instagramButton.isHidden = (d.snsInstagram?.isEmpty != false)
        xButton.isHidden = (d.snsX?.isEmpty != false)
        instagramCTAButton.isHidden = (d.snsInstagram?.isEmpty != false)

        // place/schedule
        cardPlace.update(value: d.activityPlace)
        cardSchedule.update(value: d.activitySchedule)

        // shortMessage
        let sm = (d.shortMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if sm.isEmpty {
            shortMessageLabel.text = nil
            shortMessageLabel.isHidden = true
        } else {
            shortMessageLabel.text = sm
            shortMessageLabel.isHidden = false
        }

        // members
        cardSize.update(value: d.memberSize)
        cardGender.update(value: d.genderRatio)
        cardGrade.update(value: d.grade)

        // target
        cardIntercollegiate.update(value: d.targetIntercollegiate)
        cardNonFreshmen.update(value: d.targetNonFreshmen)
        cardDoubleClub.update(value: d.targetDoubleClub)

        // ratings
        ratingActivityView.setScore(d.ratingActivity)
        ratingVibeView.setScore(d.ratingVibe)

        // message (line spacing)
        setLineSpacing(messageBody, text: d.message, spacing: 3.0)

        // fee
        if let yen = d.annualYen {
            feeRowAnnual.setValue("\(yen)円（通年）")
        } else {
            feeRowAnnual.setValue("—")
        }

        let note = (d.feeNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty {
            feeRowOther.isHidden = true
        } else {
            feeRowOther.isHidden = false
            feeRowOther.setValue(note)
        }
    }

    // MARK: - Image

    // ✅ 追加：Drive fileId 抽出
    private func extractGoogleDriveFileId(from urlString: String) -> String? {
        // open?id=xxxx / uc?...&id=xxxx / thumbnail?id=xxxx
        if let comps = URLComponents(string: urlString),
           let id = comps.queryItems?.first(where: { $0.name == "id" })?.value,
           !id.isEmpty {
            return id
        }

        // /file/d/xxxx/view
        if let range = urlString.range(of: "/file/d/") {
            let rest = urlString[range.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                let id = String(rest[..<slash])
                return id.isEmpty ? nil : id
            }
        }
        return nil
    }

    // ✅ 追加：Drive URL → 画像直リンクへ
    private func normalizedImageURLString(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if s.contains("googleusercontent.com") { return s }

        if s.contains("drive.google.com"),
           let id = extractGoogleDriveFileId(from: s) {
            return "https://drive.google.com/thumbnail?id=\(id)&sz=w1200"
            // 代替：
            // return "https://drive.google.com/uc?export=download&id=\(id)"
        }
        return s
    }

    // ✅ 置換：正規化してからロード + 失敗原因ログ
    private func loadImage(from urlString: String, into imageView: UIImageView) {
        guard let normalized = normalizedImageURLString(urlString),
              let url = URL(string: normalized) else { return }

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                print("image load error:", error.localizedDescription, "url:", normalized)
                return
            }

            if let http = response as? HTTPURLResponse {
                let mime = response?.mimeType ?? "-"
                if !(200...299).contains(http.statusCode) {
                    print("image load http:", http.statusCode, "mime:", mime, "url:", normalized)
                }
            }

            guard let data = data, let img = UIImage(data: data) else {
                let mime = response?.mimeType ?? "-"
                print("image decode failed. mime:", mime, "url:", normalized)
                return
            }

            DispatchQueue.main.async {
                imageView.image = img
                imageView.contentMode = .scaleAspectFill
            }
        }.resume()
    }

    // MARK: - SNS

    private func makeSNSButton(assetName: String,
                               renderingMode: UIImage.RenderingMode,
                               imageInsets: UIEdgeInsets,
                               fallbackSystemName: String,
                               action: Selector) -> UIButton {

        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false

        let img = UIImage(named: assetName)?.withRenderingMode(renderingMode)
            ?? UIImage(systemName: fallbackSystemName)

        btn.setImage(img, for: .normal)
        btn.contentEdgeInsets = imageInsets
        btn.tintColor = (renderingMode == .alwaysTemplate) ? .label : nil
        btn.addTarget(self, action: action, for: .touchUpInside)

        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 34),
            btn.widthAnchor.constraint(equalToConstant: 34)
        ])
        return btn
    }

    @objc private func tapInstagram() {
        guard let handle = detail?.snsInstagram, !handle.isEmpty else { return }
        openURL("https://www.instagram.com/\(handle)")
    }

    @objc private func tapX() {
        guard let handle = detail?.snsX, !handle.isEmpty else { return }
        openURL("https://x.com/\(handle)")
    }

    @objc private func tapInstagramCTA() {
        tapInstagram()
    }

    private func openURL(_ str: String) {
        guard let url = URL(string: str) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Bookmark

    @objc private func didTapBookmark() {
        guard let d = detail else { return }
        BookmarkManager.shared.toggle(circleId: d.id, name: d.name, kind: d.category ?? "その他")
        updateBookmarkButtonUI()
        NotificationCenter.default.post(name: Self.bookmarkDidChangeName, object: nil)
    }

    @objc private func bookmarkDidChange() {
        updateBookmarkButtonUI()
    }

    private func updateBookmarkButtonUI() {
        guard let d = detail else { return }
        let isSaved = BookmarkManager.shared.isBookmarked(circleId: d.id)
        bookmarkButton.setImage(UIImage(systemName: isSaved ? "bookmark.fill" : "bookmark"), for: .normal)
    }
}

// MARK: - Bookmark Manager (in-file to avoid "not in scope")

final class BookmarkManager {
    static let shared = BookmarkManager()
    private let key = "circle_bookmarks_v1"

    struct Bookmark: Codable, Hashable {
        let circleId: String
        let name: String
        let kind: String
    }

    private init() {}

    func all() -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    func isBookmarked(circleId: String) -> Bool {
        return all().contains(where: { $0.circleId == circleId })
    }

    func toggle(circleId: String, name: String, kind: String) {
        var list = all()
        if let idx = list.firstIndex(where: { $0.circleId == circleId }) {
            list.remove(at: idx)
        } else {
            list.append(Bookmark(circleId: circleId, name: name, kind: kind))
        }
        save(list)
    }

    private func save(_ list: [Bookmark]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
