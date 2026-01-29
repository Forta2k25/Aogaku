//
//  CircleDetailViewController.swift
//  Aogaku
//
//  Created by shu m on 2026/01/27.
//
import UIKit
import FirebaseFirestore

// MARK: - Models (Detail)

struct CircleDetail: Hashable {
    let id: String

    var name: String
    var campus: String
    var intensity: String
    var popularity: Int

    var category: String?
    var tags: [String]

    var imageURLs: [String]          // 詳細用（複数）
    var fallbackImageURL: String?    // ない場合の保険

    var snsInstagram: String?
    var snsX: String?
    var snsWebsite: String?

    var activityPlace: String?
    var activitySchedule: String?

    var memberSize: String?
    var genderRatio: String?
    var grade: String?

    var annualFeeYen: Int?
    var feeNote: String?

    var message: String?
    var features: [String]

    var beforeJoinTarget: String?
    var beforeJoinNonFreshman: String?
    var beforeJoinSelection: String?
    var beforeJoinPartTime: String?

    static func from(id: String, data: [String: Any]) -> CircleDetail {
        let imageURLs = data["imageURLs"] as? [String] ?? []
        let tags = data["tags"] as? [String] ?? []
        let features = data["features"] as? [String] ?? []

        // ✅ Firebase: sns はネストMAP想定
        let sns = data["sns"] as? [String: Any]
        let activity = data["activity"] as? [String: Any]
        let members = data["members"] as? [String: Any]
        let fee = data["fee"] as? [String: Any]
        let beforeJoin = data["beforeJoin"] as? [String: Any]

        return CircleDetail(
            id: id,
            name: data["name"] as? String ?? "",
            campus: data["campus"] as? String ?? "",
            intensity: data["intensity"] as? String ?? "",
            popularity: data["popularity"] as? Int ?? 0,

            category: data["category"] as? String,
            tags: tags,

            imageURLs: imageURLs,
            fallbackImageURL: data["imageURL"] as? String,

            snsInstagram: sns?["instagram"] as? String,
            snsX: sns?["x"] as? String,
            snsWebsite: sns?["website"] as? String,

            activityPlace: activity?["place"] as? String,
            activitySchedule: activity?["schedule"] as? String,

            memberSize: members?["size"] as? String,
            genderRatio: members?["genderRatio"] as? String,
            grade: members?["grade"] as? String,

            annualFeeYen: fee?["annualYen"] as? Int,
            feeNote: fee?["note"] as? String,

            message: data["message"] as? String,
            features: features,

            beforeJoinTarget: beforeJoin?["target"] as? String,
            beforeJoinNonFreshman: beforeJoin?["nonFreshman"] as? String,
            beforeJoinSelection: beforeJoin?["selection"] as? String,
            beforeJoinPartTime: beforeJoin?["partTime"] as? String
        )
    }
}

// MARK: - UI Helpers

final class InfoCardView: UIView {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    private func primaryTextColor() -> UIColor {
        UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return .label
            } else {
                return UIColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1) // #333333
            }
        }
    }

    init(title: String, value: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 14

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabel

        valueLabel.text = (value?.isEmpty == false) ? value : "—"
        valueLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = primaryTextColor()
        valueLabel.numberOfLines = 2
        valueLabel.lineBreakMode = .byTruncatingTail

        // ✅ 伸びないように（上詰めを安定させる）
        valueLabel.setContentHuggingPriority(.required, for: .vertical)
        valueLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        addSubview(titleLabel)
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            // タイトル
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            // 値（✅ bottom を <= にして、ラベルを引き伸ばさない）
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            valueLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),

            // ✅ カード高さは固定（左右で統一）
            self.heightAnchor.constraint(equalToConstant: 92)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: String?) {
        valueLabel.text = (value?.isEmpty == false) ? value : "—"
    }
}


final class TagLabel: UILabel {
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

// MARK: - VC

final class CircleDetailViewController: UIViewController {

    private let circleId: String
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    private var detail: CircleDetail?

    // MARK: UI

    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let headerImageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .tertiarySystemFill
        return iv
    }()

    private let pageControl: UIPageControl = {
        let pc = UIPageControl()
        pc.translatesAutoresizingMaskIntoConstraints = false
        pc.hidesForSinglePage = true
        return pc
    }()

    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = .systemFont(ofSize: 26, weight: .bold)
        lb.textColor = .label
        lb.numberOfLines = 2
        return lb
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

    private let snsStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 10
        st.alignment = .center
        return st
    }()

    private var instagramButton: UIButton!
    private var xButton: UIButton!
    private var websiteButton: UIButton!

    private let grid1 = UIStackView()
    private let grid2 = UIStackView()
    private let grid3 = UIStackView()

    private let messageTitle = UILabel()
    private let messageBody = UILabel()

    private let featureTitle = UILabel()
    private let featureBody = UILabel()

    private var cardPlace: InfoCardView!
    private var cardSchedule: InfoCardView!
    private var cardSize: InfoCardView!
    private var cardGender: InfoCardView!
    private var cardGrade: InfoCardView!
    private var cardFee: InfoCardView!

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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        listener?.remove()
        listener = nil
    }

    // MARK: - Firestore

    private func startListening() {
        listener?.remove()
        listener = db.collection("circle").document(circleId).addSnapshotListener { [weak self] snap, error in
            guard let self else { return }
            if let error {
                print("Circle detail listen error:", error)
                return
            }
            guard let data = snap?.data() else { return }

            let d = CircleDetail.from(id: circleId, data: data)
            self.detail = d
            self.applyDetail(d)
        }
    }

    // MARK: - UI

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        contentView.addSubview(headerImageView)
        contentView.addSubview(pageControl)

        NSLayoutConstraint.activate([
            headerImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerImageView.heightAnchor.constraint(equalToConstant: 280),

            pageControl.bottomAnchor.constraint(equalTo: headerImageView.bottomAnchor, constant: -10),
            pageControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])

        // タイトルブロック
        let titleBlock = UIStackView(arrangedSubviews: [titleLabel, categoryLabel, tagsStack, snsStack])
        titleBlock.translatesAutoresizingMaskIntoConstraints = false
        titleBlock.axis = .vertical
        titleBlock.spacing = 10
        titleBlock.alignment = .leading
        contentView.addSubview(titleBlock)

        NSLayoutConstraint.activate([
            titleBlock.topAnchor.constraint(equalTo: headerImageView.bottomAnchor, constant: 14),
            titleBlock.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleBlock.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])

        // SNS buttons
        instagramButton = makeSNSButton(assetName: "instagram",
                                        renderingMode: .alwaysOriginal,
                                        imageInsets: UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5),
                                        fallbackSystemName: "camera",
                                        action: #selector(tapInstagram))

        xButton = makeSNSButton(assetName: "X",
                                renderingMode: .alwaysTemplate,
                                imageInsets: UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
                                fallbackSystemName: "xmark",
                                action: #selector(tapX))

        websiteButton = makeSNSButton(systemName: "link", action: #selector(tapWebsite))


        snsStack.addArrangedSubview(instagramButton)
        snsStack.addArrangedSubview(xButton)
        snsStack.addArrangedSubview(websiteButton)

        // Cards grid
        cardPlace = InfoCardView(title: "活動場所", value: nil)
        cardSchedule = InfoCardView(title: "活動日時", value: nil)
        cardSize = InfoCardView(title: "人数", value: nil)
        cardGender = InfoCardView(title: "男女比", value: nil)
        cardGrade = InfoCardView(title: "学年", value: nil)
        cardFee = InfoCardView(title: "費用", value: nil)

        grid1.axis = .horizontal
        grid1.spacing = 12
        grid1.distribution = .fillEqually
        grid1.translatesAutoresizingMaskIntoConstraints = false
        grid1.addArrangedSubview(cardPlace)
        grid1.addArrangedSubview(cardSchedule)

        grid2.axis = .horizontal
        grid2.spacing = 12
        grid2.distribution = .fillEqually
        grid2.translatesAutoresizingMaskIntoConstraints = false
        grid2.addArrangedSubview(cardSize)
        grid2.addArrangedSubview(cardGender)

        grid3.axis = .horizontal
        grid3.spacing = 12
        grid3.distribution = .fillEqually
        grid3.translatesAutoresizingMaskIntoConstraints = false
        grid3.addArrangedSubview(cardGrade)
        grid3.addArrangedSubview(cardFee)

        let gridStack = UIStackView(arrangedSubviews: [grid1, grid2, grid3])
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridStack.axis = .vertical
        gridStack.spacing = 12
        contentView.addSubview(gridStack)

        NSLayoutConstraint.activate([
            gridStack.topAnchor.constraint(equalTo: titleBlock.bottomAnchor, constant: 16),
            gridStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            gridStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])

        // Message
        messageTitle.translatesAutoresizingMaskIntoConstraints = false
        messageTitle.text = "団体からのメッセージ"
        messageTitle.font = .systemFont(ofSize: 18, weight: .bold)

        messageBody.translatesAutoresizingMaskIntoConstraints = false
        messageBody.font = .systemFont(ofSize: 14, weight: .regular)
        messageBody.textColor = .label
        messageBody.numberOfLines = 0

        // Features
        featureTitle.translatesAutoresizingMaskIntoConstraints = false
        featureTitle.text = "団体の特徴"
        featureTitle.font = .systemFont(ofSize: 18, weight: .bold)

        featureBody.translatesAutoresizingMaskIntoConstraints = false
        featureBody.font = .systemFont(ofSize: 14, weight: .regular)
        featureBody.textColor = .label
        featureBody.numberOfLines = 0

        let sections = UIStackView(arrangedSubviews: [messageTitle, messageBody, featureTitle, featureBody])
        sections.translatesAutoresizingMaskIntoConstraints = false
        sections.axis = .vertical
        sections.spacing = 10

        contentView.addSubview(sections)

        NSLayoutConstraint.activate([
            sections.topAnchor.constraint(equalTo: gridStack.bottomAnchor, constant: 20),
            sections.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sections.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            sections.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    // MARK: - SNS Button Factory

    private func makeSNSButton(systemName: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false

        btn.setImage(UIImage(systemName: systemName)?.withRenderingMode(.alwaysTemplate), for: .normal)
        btn.tintColor = .label
        btn.backgroundColor = .secondarySystemGroupedBackground
        btn.layer.cornerRadius = 20
        btn.clipsToBounds = true
        btn.imageView?.contentMode = .scaleAspectFit

        btn.addTarget(self, action: action, for: .touchUpInside)

        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 40),
            btn.widthAnchor.constraint(equalToConstant: 40)
        ])
        return btn
    }

    private func makeSNSButton(
        assetName: String,
        renderingMode: UIImage.RenderingMode,
        imageInsets: UIEdgeInsets,
        fallbackSystemName: String,
        action: Selector
    ) -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false

        // 画像
        let assetImg = UIImage(named: assetName)?.withRenderingMode(renderingMode)
        let fallback = UIImage(systemName: fallbackSystemName)?.withRenderingMode(.alwaysTemplate)
        btn.setImage(assetImg ?? fallback, for: .normal)

        // 見た目
        btn.backgroundColor = .secondarySystemGroupedBackground
        btn.layer.cornerRadius = 20
        btn.clipsToBounds = true
        btn.imageView?.contentMode = .scaleAspectFit

        // ✅ ここで「少し小さく」描画して端切れ防止
        btn.contentEdgeInsets = imageInsets

        // tint は Template のときだけ効かせる（Originalは色そのまま）
        btn.tintColor = (renderingMode == .alwaysTemplate) ? .label : nil

        btn.addTarget(self, action: action, for: .touchUpInside)

        NSLayoutConstraint.activate([
            btn.heightAnchor.constraint(equalToConstant: 40),
            btn.widthAnchor.constraint(equalToConstant: 40)
        ])
        return btn
    }


    
    // MARK: - Apply data

    private func applyDetail(_ d: CircleDetail) {
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

        // SNS（値が空ならボタン非表示）
        instagramButton.isHidden = (d.snsInstagram?.isEmpty != false)
        xButton.isHidden = (d.snsX?.isEmpty != false)
        websiteButton.isHidden = (d.snsWebsite?.isEmpty != false)

        // cards
        cardPlace.update(value: d.activityPlace)
        cardSchedule.update(value: d.activitySchedule)
        cardSize.update(value: d.memberSize)
        cardGender.update(value: d.genderRatio)
        cardGrade.update(value: d.grade)

        if let yen = d.annualFeeYen {
            let note = (d.feeNote?.isEmpty == false) ? "（\(d.feeNote!)）" : ""
            cardFee.update(value: "\(yen)円\(note)")
        } else {
            cardFee.update(value: d.feeNote)
        }

        messageBody.text = (d.message?.isEmpty == false) ? d.message : "—"

        if d.features.isEmpty {
            featureBody.text = "—"
        } else {
            featureBody.text = d.features.map { "・\($0)" }.joined(separator: "\n")
        }

        // header image（複数枚の先頭を表示、なければ fallback）
        let urls = !d.imageURLs.isEmpty ? d.imageURLs : (d.fallbackImageURL != nil ? [d.fallbackImageURL!] : [])
        pageControl.numberOfPages = max(urls.count, 1)
        pageControl.currentPage = 0

        if let first = urls.first {
            loadImage(from: first, into: headerImageView)
        } else {
            headerImageView.image = nil
        }
    }

    // MARK: - Open SNS

    @objc private func tapInstagram() {
        guard let raw = detail?.snsInstagram, !raw.isEmpty else { return }
        guard let url = normalizedSNSURL(platform: .instagram, raw: raw) else { return }
        openURL(url)
    }

    @objc private func tapX() {
        guard let raw = detail?.snsX, !raw.isEmpty else { return }
        guard let url = normalizedSNSURL(platform: .x, raw: raw) else { return }
        openURL(url)
    }

    @objc private func tapWebsite() {
        guard let raw = detail?.snsWebsite, !raw.isEmpty else { return }
        guard let url = normalizedSNSURL(platform: .website, raw: raw) else { return }
        openURL(url)
    }

    private enum SNSPlatform { case instagram, x, website }

    /// Firestore側が「ハンドル」でも「URL」でも動くように正規化
    private func normalizedSNSURL(platform: SNSPlatform, raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        let lower = s.lowercased()

        // すでにURL
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: s)
        }

        // @を消す
        let noAt = s.replacingOccurrences(of: "@", with: "")

        switch platform {
        case .instagram:
            if noAt.contains("instagram.com/") {
                return URL(string: noAt.hasPrefix("http") ? noAt : "https://\(noAt)")
            }
            return URL(string: "https://instagram.com/\(noAt)")

        case .x:
            if noAt.contains("x.com/") {
                return URL(string: noAt.hasPrefix("http") ? noAt : "https://\(noAt)")
            }
            if noAt.contains("twitter.com/") {
                return URL(string: noAt.hasPrefix("http") ? noAt : "https://\(noAt)")
            }
            return URL(string: "https://x.com/\(noAt)")

        case .website:
            // websiteはURL想定。schemeが無ければ https を付ける
            return URL(string: "https://\(s)")
        }
    }

    private func openURL(_ url: URL) {
        UIApplication.shared.open(url)
    }

    // MARK: - Image loading (simple)

    private static let imageCache = NSCache<NSString, UIImage>()

    private func loadImage(from urlString: String, into imageView: UIImageView) {
        if let cached = Self.imageCache.object(forKey: urlString as NSString) {
            imageView.image = cached
            return
        }
        guard let url = URL(string: urlString) else {
            imageView.image = nil
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            Self.imageCache.setObject(img, forKey: urlString as NSString)
            DispatchQueue.main.async { imageView.image = img }
        }.resume()
    }
}
