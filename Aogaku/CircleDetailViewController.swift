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

    // ✅ 追加
    var totalMemberCountText: String?

    // ✅ もともと「人数」に出していた文字列
    var memberSize: String?

    var genderRatio: String?
    var grade: String?

    var targetIntercollegiate: String?
    var targetNonFreshmen: String?
    var targetDoubleClub: String?

    var annualYen: Int?
    var feeNote: String?

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

        func intValue(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let s = any as? String { return Int(s) }
            return nil
        }

        func stringValue(_ any: Any?) -> String? {
            if let s = any as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if let i = any as? Int { return "\(i)人" }
            if let d = any as? Double, d.rounded() == d { return "\(Int(d))人" }
            return nil
        }

        // ✅ AC列の合計人数をどこに入れていても拾いやすくしておく
        let totalMemberCountText =
            stringValue(members?["total"]) ??
            stringValue(members?["totalCount"]) ??
            stringValue(members?["count"]) ??
            stringValue(data["totalMembers"]) ??
            stringValue(data["memberCount"]) ??
            stringValue(data["totalCount"]) ??
            stringValue(data["人数"]) // 念のため

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

            totalMemberCountText: totalMemberCountText,
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

    private let minHeight: CGFloat
    private let centerValue: Bool

    init(title: String,
         value: String?,
         style: Style,
         minHeight: CGFloat = 62,
         valueFont: UIFont,
         valueNumberOfLines: Int,
         shrinkToFit: Bool,
         centerValue: Bool) {

        self.minHeight = minHeight
        self.centerValue = centerValue

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
        titleLabel.numberOfLines = 1

        valueLabel.text = normalizedText(value)
        valueLabel.font = valueFont
        valueLabel.numberOfLines = valueNumberOfLines
        valueLabel.textColor = UIColor { trait in
            if trait.userInterfaceStyle == .dark { return .label }
            return UIColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1)
        }
        valueLabel.lineBreakMode = .byWordWrapping
        
        titleLabel.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        valueLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        valueLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        if centerValue {
            valueLabel.textAlignment = .center
        } else {
            valueLabel.textAlignment = .left
        }

        if shrinkToFit, valueNumberOfLines == 1 {
            valueLabel.adjustsFontSizeToFitWidth = true
            valueLabel.minimumScaleFactor = 0.75
            valueLabel.baselineAdjustment = .alignCenters
        } else {
            valueLabel.adjustsFontSizeToFitWidth = false
        }

        addSubview(titleLabel)
        addSubview(valueLabel)

        let minHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight)
        minHeightConstraint.priority = .required

        NSLayoutConstraint.activate([
            minHeightConstraint,

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        if centerValue {
            NSLayoutConstraint.activate([
                valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
                valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
            ])
        } else {
            NSLayoutConstraint.activate([
                valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
                valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
            ])
        }

        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: String?) {
        valueLabel.text = normalizedText(value)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func normalizedText(_ value: String?) -> String {
        let t = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "—" : t
    }
}

/// ✅ 費用の行（灰色角丸／高さ短め／中央に値／文字小さめ）
fileprivate final class FeeRowView: UIView {
    private let leftLabel = UILabel()
    private let centerLabel = UILabel()
    private var minHeightConstraint: NSLayoutConstraint!

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
        leftLabel.numberOfLines = 1
        leftLabel.setContentHuggingPriority(.required, for: .horizontal)
        leftLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        centerLabel.translatesAutoresizingMaskIntoConstraints = false
        centerLabel.text = "—"
        centerLabel.font = .systemFont(ofSize: 16, weight: .bold)
        centerLabel.textAlignment = .left
        centerLabel.textColor = UIColor { trait in
            if trait.userInterfaceStyle == .dark { return .label }
            return UIColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1)
        }

        // ✅ 長文を複数行で全部表示
        centerLabel.numberOfLines = 0
        centerLabel.lineBreakMode = .byWordWrapping
        centerLabel.adjustsFontSizeToFitWidth = false
        centerLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        centerLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)

        addSubview(leftLabel)
        addSubview(centerLabel)

        minHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: 52)

        NSLayoutConstraint.activate([
            minHeightConstraint,

            leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            leftLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            leftLabel.widthAnchor.constraint(equalToConstant: 84),

            centerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            centerLabel.leadingAnchor.constraint(equalTo: leftLabel.trailingAnchor, constant: 12),
            centerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            centerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
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
    
    private var currentHeaderImages: [UIImage] = []
    private var currentHeaderImageURLs: [String] = []

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
                                 minHeight: 62,
                                 valueFont: .systemFont(ofSize: 15, weight: .semibold),
                                 valueNumberOfLines: 2,
                                 shrinkToFit: false,
                                 centerValue: false)

        cardSchedule = InfoCardView(title: "活動日時", value: nil,
                                    style: .filled(background: grayBG()),
                                    minHeight: 62,
                                    valueFont: .systemFont(ofSize: 15, weight: .semibold),
                                    valueNumberOfLines: 2,
                                    shrinkToFit: false,
                                    centerValue: false)

        grid1.axis = .horizontal
        grid1.spacing = 14
        grid1.alignment = .fill
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
                                minHeight: 88,
                                valueFont: .systemFont(ofSize: 14, weight: .bold),
                                valueNumberOfLines: 0,
                                shrinkToFit: false,
                                centerValue: true)

        cardGender = InfoCardView(title: "男女比", value: nil,
                                  style: .outlined(border: border),
                                  minHeight: 88,
                                  valueFont: .systemFont(ofSize: 14, weight: .bold),
                                  valueNumberOfLines: 1,
                                  shrinkToFit: true,
                                  centerValue: true)

        cardGrade = InfoCardView(title: "学年", value: nil,
                                 style: .outlined(border: border),
                                 minHeight: 88,
                                 valueFont: .systemFont(ofSize: 12, weight: .bold),
                                 valueNumberOfLines: 0,
                                 shrinkToFit: false,
                                 centerValue: true)

        memberRow.axis = .horizontal
        memberRow.spacing = 14
        memberRow.alignment = .fill
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
                                           minHeight: 88,
                                           valueFont: .systemFont(ofSize: 14, weight: .bold),
                                           valueNumberOfLines: 2,
                                           shrinkToFit: true,
                                           centerValue: true)

        cardNonFreshmen = InfoCardView(title: "新入生以外", value: nil,
                                       style: .outlined(border: border),
                                       minHeight: 88,
                                       valueFont: .systemFont(ofSize: 14, weight: .bold),
                                       valueNumberOfLines: 2,
                                       shrinkToFit: true,
                                       centerValue: true)

        cardDoubleClub = InfoCardView(title: "兼サー", value: nil,
                                      style: .outlined(border: border),
                                      minHeight: 88,
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
        feeRowOther = FeeRowView(leftText: "その他", bg: grayBG())

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
        iv.isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapHeaderImage(_:)))
        iv.addGestureRecognizer(tap)

        return iv
    }

    private func reloadHeaderImages(with urls: [String]) {
        headerImagesStack.arrangedSubviews.forEach { v in
            headerImagesStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        currentHeaderImages = []
        currentHeaderImageURLs = []

        let valid = urls.filter { !$0.isEmpty }
        pageControl.numberOfPages = max(valid.count, 1)
        pageControl.currentPage = 0

        let useURLs = valid.isEmpty ? [detail?.fallbackImageURL].compactMap { $0 } : valid
        let finalURLs = useURLs.isEmpty ? [""] : useURLs
        currentHeaderImageURLs = finalURLs

        for (index, url) in finalURLs.enumerated() {
            let iv = makeHeaderImageView()
            iv.tag = index

            headerImagesStack.addArrangedSubview(iv)
            NSLayoutConstraint.activate([
                iv.widthAnchor.constraint(equalTo: headerScrollView.frameLayoutGuide.widthAnchor),
                iv.heightAnchor.constraint(equalTo: headerScrollView.frameLayoutGuide.heightAnchor)
            ])

            if !url.isEmpty {
                loadImage(from: url, into: iv) { [weak self] image in
                    guard let self = self else { return }

                    if self.currentHeaderImages.count <= index {
                        self.currentHeaderImages += Array(
                            repeating: UIImage(),
                            count: index - self.currentHeaderImages.count + 1
                        )
                    }
                    self.currentHeaderImages[index] = image
                }
            } else {
                let placeholder = UIImage(systemName: "photo")
                iv.image = placeholder
                iv.tintColor = .secondaryLabel
                iv.contentMode = .scaleAspectFit

                if let placeholder {
                    if currentHeaderImages.count <= index {
                        currentHeaderImages += Array(
                            repeating: UIImage(),
                            count: index - currentHeaderImages.count + 1
                        )
                    }
                    currentHeaderImages[index] = placeholder
                }
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

        tagsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if d.tags.isEmpty {
            tagsStack.isHidden = true
        } else {
            tagsStack.isHidden = false
            d.tags.prefix(4).forEach { tag in
                tagsStack.addArrangedSubview(TagLabel(text: tag))
            }
        }

        instagramButton.isHidden = (d.snsInstagram?.isEmpty != false)
        xButton.isHidden = (d.snsX?.isEmpty != false)
        instagramCTAButton.isHidden = (d.snsInstagram?.isEmpty != false)

        cardPlace.update(value: d.activityPlace)
        cardSchedule.update(value: d.activitySchedule)

        let sm = (d.shortMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if sm.isEmpty {
            shortMessageLabel.text = nil
            shortMessageLabel.isHidden = true
        } else {
            shortMessageLabel.text = sm
            shortMessageLabel.isHidden = false
        }

        // ✅ members
        cardSize.update(value: d.totalMemberCountText ?? d.memberSize)

        // 男女比はそのまま
        cardGender.update(value: d.genderRatio)

        // ✅ 今まで「人数」に出していた内容を「学年」へ
        cardGrade.update(value: d.memberSize ?? d.grade)

        cardIntercollegiate.update(value: d.targetIntercollegiate)
        cardNonFreshmen.update(value: d.targetNonFreshmen)
        cardDoubleClub.update(value: d.targetDoubleClub)

        ratingActivityView.setScore(d.ratingActivity)
        ratingVibeView.setScore(d.ratingVibe)

        setLineSpacing(messageBody, text: d.message, spacing: 3.0)

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
    
    @objc private func didTapHeaderImage(_ gesture: UITapGestureRecognizer) {
        guard let tappedView = gesture.view as? UIImageView else { return }
        let index = tappedView.tag

        let validImages = currentHeaderImages.enumerated().compactMap { _, image -> UIImage? in
            image.size.width > 0 && image.size.height > 0 ? image : nil
        }

        guard !validImages.isEmpty else { return }

        let safeIndex = min(index, validImages.count - 1)

        let viewer = FullScreenImageViewController(
            images: validImages,
            initialIndex: safeIndex
        )
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: true)
    }

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
    private func loadImage(from urlString: String,
                           into imageView: UIImageView,
                           completion: ((UIImage) -> Void)? = nil) {
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
                completion?(img)
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

final class FullScreenImageViewController: UIViewController, UIScrollViewDelegate {

    private let images: [UIImage]
    private let initialIndex: Int

    private let pagingScrollView = UIScrollView()
    private let closeButton = UIButton(type: .system)
    private let pageLabel = UILabel()

    private var zoomScrollViews: [UIScrollView] = []
    private var currentPageIndex: Int
    private var hasAppliedInitialOffset = false
    private var lastPagingBoundsSize: CGSize = .zero
    private var pageContainers: [UIView] = []
   

    init(images: [UIImage], initialIndex: Int) {
        self.images = images
        self.initialIndex = initialIndex
        self.currentPageIndex = initialIndex
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        pagingScrollView.translatesAutoresizingMaskIntoConstraints = false
        pagingScrollView.isPagingEnabled = true
        pagingScrollView.showsHorizontalScrollIndicator = false
        pagingScrollView.showsVerticalScrollIndicator = false
        pagingScrollView.alwaysBounceVertical = false
        pagingScrollView.alwaysBounceHorizontal = images.count > 1
        pagingScrollView.delegate = self
        view.addSubview(pagingScrollView)

        NSLayoutConstraint.activate([
            pagingScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            pagingScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagingScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pagingScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        for image in images {
            let pageContainer = UIView()
            pageContainer.backgroundColor = .black
            pagingScrollView.addSubview(pageContainer)
            pageContainers.append(pageContainer)

            let zoomScrollView = UIScrollView()
            zoomScrollView.backgroundColor = .black
            zoomScrollView.delegate = self
            zoomScrollView.minimumZoomScale = 1.0
            zoomScrollView.maximumZoomScale = 4.0
            zoomScrollView.zoomScale = 1.0
            zoomScrollView.showsHorizontalScrollIndicator = false
            zoomScrollView.showsVerticalScrollIndicator = false
            zoomScrollView.bouncesZoom = true
            zoomScrollView.alwaysBounceVertical = false
            zoomScrollView.alwaysBounceHorizontal = false
            // 追加
            
            zoomScrollView.bounces = false
            zoomScrollView.isScrollEnabled = false
            zoomScrollView.panGestureRecognizer.isEnabled = false
            //zoomScrollView.panGestureRecognizer.minimumNumberOfTouches = 2
            
            pageContainer.addSubview(zoomScrollView)
            zoomScrollViews.append(zoomScrollView)

            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black
            imageView.clipsToBounds = true
            imageView.tag = 999
            zoomScrollView.addSubview(imageView)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            imageView.isUserInteractionEnabled = true
            imageView.addGestureRecognizer(doubleTap)
        }

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeButton.layer.cornerRadius = 24
        closeButton.clipsToBounds = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.textColor = .white
        pageLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        pageLabel.textAlignment = .center
        view.addSubview(pageLabel)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 48),
            closeButton.heightAnchor.constraint(equalToConstant: 48),

            pageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let pageWidth = pagingScrollView.bounds.width
        let pageHeight = pagingScrollView.bounds.height
        let boundsSize = pagingScrollView.bounds.size

        pagingScrollView.contentSize = CGSize(width: pageWidth * CGFloat(images.count), height: pageHeight)

        for (index, pageContainer) in pageContainers.enumerated() {
            pageContainer.frame = CGRect(
                x: CGFloat(index) * pageWidth,
                y: 0,
                width: pageWidth,
                height: pageHeight
            )

            let zoomScrollView = zoomScrollViews[index]
            zoomScrollView.frame = pageContainer.bounds
            zoomScrollView.contentInsetAdjustmentBehavior = .never

            if let imageView = zoomScrollView.viewWithTag(999) as? UIImageView {
                let image = images[index]
                let fittedFrame = aspectFitFrame(for: image.size, in: zoomScrollView.bounds)

                if zoomScrollView.zoomScale <= 1.01 {
                    imageView.frame = fittedFrame
                    zoomScrollView.contentSize = fittedFrame.size
                    zoomScrollView.zoomScale = 1.0
                    zoomScrollView.contentOffset = .zero
                }

                centerImageView(imageView, in: zoomScrollView)

                let isZoomed = zoomScrollView.zoomScale > 1.01
                zoomScrollView.isScrollEnabled = isZoomed
                zoomScrollView.panGestureRecognizer.isEnabled = isZoomed
            }
        }

        let shouldReposition = !hasAppliedInitialOffset || lastPagingBoundsSize != boundsSize
        if shouldReposition {
            let targetX = CGFloat(currentPageIndex) * pageWidth
            pagingScrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
            hasAppliedInitialOffset = true
            lastPagingBoundsSize = boundsSize
        }

        updatePageLabel()
    }

    private func aspectFitFrame(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (bounds.width - width) / 2
        let y = (bounds.height - height) / 2

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func centerImageView(_ imageView: UIImageView, in scrollView: UIScrollView) {
        let boundsSize = scrollView.bounds.size
        var frameToCenter = imageView.frame

        frameToCenter.origin.x = frameToCenter.width < boundsSize.width
            ? (boundsSize.width - frameToCenter.width) / 2
            : 0

        frameToCenter.origin.y = frameToCenter.height < boundsSize.height
            ? (boundsSize.height - frameToCenter.height) / 2
            : 0

        imageView.frame = frameToCenter
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        guard scrollView != pagingScrollView else { return nil }
        return scrollView.viewWithTag(999)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView != pagingScrollView,
              let imageView = scrollView.viewWithTag(999) as? UIImageView else { return }

        centerImageView(imageView, in: scrollView)

        let isZoomed = scrollView.zoomScale > 1.01
        scrollView.isScrollEnabled = isZoomed
        scrollView.panGestureRecognizer.isEnabled = isZoomed
        pagingScrollView.isScrollEnabled = !isZoomed
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard scrollView != pagingScrollView else { return }
        pagingScrollView.isScrollEnabled = false
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scrollView != pagingScrollView else { return }

        let isZoomed = scale > 1.01
        scrollView.isScrollEnabled = isZoomed
        scrollView.panGestureRecognizer.isEnabled = isZoomed
        pagingScrollView.isScrollEnabled = !isZoomed

        if !isZoomed,
           let imageView = scrollView.viewWithTag(999) as? UIImageView,
           let pageIndex = zoomScrollViews.firstIndex(where: { $0 == scrollView }) {
            let image = images[pageIndex]
            let fittedFrame = aspectFitFrame(for: image.size, in: scrollView.bounds)
            imageView.frame = fittedFrame
            scrollView.contentSize = fittedFrame.size
            scrollView.contentOffset = .zero
            centerImageView(imageView, in: scrollView)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView else { return }
        updatePageLabel()
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView else { return }
        syncCurrentPageIndex()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView == pagingScrollView else { return }
        if !decelerate {
            syncCurrentPageIndex()
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView else { return }
        syncCurrentPageIndex()
    }

    private func syncCurrentPageIndex() {
        let width = max(pagingScrollView.bounds.width, 1)
        currentPageIndex = min(
            max(Int((pagingScrollView.contentOffset.x + width / 2) / width), 0),
            images.count - 1
        )
        updatePageLabel()
    }

    private func updatePageLabel() {
        let width = max(pagingScrollView.bounds.width, 1)
        let page = Int((pagingScrollView.contentOffset.x + width / 2) / width) + 1
        pageLabel.text = "\(min(max(page, 1), images.count)) / \(images.count)"
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let imageView = gesture.view as? UIImageView,
              let zoomScrollView = imageView.superview as? UIScrollView else { return }

        if zoomScrollView.zoomScale > 1.01 {
            zoomScrollView.setZoomScale(1.0, animated: true)
            zoomScrollView.isScrollEnabled = false
            zoomScrollView.panGestureRecognizer.isEnabled = false
            pagingScrollView.isScrollEnabled = true
            return
        }

        let tapPoint = gesture.location(in: imageView)
        let targetZoomScale = min(zoomScrollView.maximumZoomScale, 3.0)

        let width = zoomScrollView.bounds.width / targetZoomScale
        let height = zoomScrollView.bounds.height / targetZoomScale
        let originX = tapPoint.x - (width / 2)
        let originY = tapPoint.y - (height / 2)

        let zoomRect = CGRect(x: originX, y: originY, width: width, height: height)
        zoomScrollView.zoom(to: zoomRect, animated: true)
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
