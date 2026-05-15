// WriteReviewViewController.swift
// Aogaku

import UIKit
import FirebaseAuth

// MARK: - PipRatingView
// 左ラベル  ○ ○ ○ ○ ○  右ラベル  の5択コンポーネント

final class PipRatingView: UIView {

    var onSelect: ((Int) -> Void)?
    private(set) var selected = 0

    private let pips: [UIButton]
    private let leftLabel = UILabel()
    private let rightLabel = UILabel()

    private let green = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)

    init(leftText: String, rightText: String) {
        pips = (1...5).map { i in
            let b = UIButton(type: .custom)
            b.tag = i
            return b
        }
        super.init(frame: .zero)
        setup(leftText: leftText, rightText: rightText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup(leftText: String, rightText: String) {
        for label in [leftLabel, rightLabel] {
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            // 固定幅にして2行間でピップ位置を揃える
            label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        leftLabel.text = leftText
        rightLabel.text = rightText

        let pipStack = UIStackView(arrangedSubviews: pips)
        pipStack.axis = .horizontal
        pipStack.spacing = 10
        pipStack.distribution = .equalSpacing
        pipStack.alignment = .center

        let row = UIStackView(arrangedSubviews: [leftLabel, pipStack, rightLabel])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 44)
        ])

        for pip in pips {
            pip.layer.cornerRadius = 14
            pip.layer.borderWidth = 1.5
            pip.layer.borderColor = UIColor.systemGray4.cgColor
            pip.backgroundColor = .systemGray6
            pip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                pip.widthAnchor.constraint(equalToConstant: 28),
                pip.heightAnchor.constraint(equalToConstant: 28)
            ])
            pip.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        let value = sender.tag
        guard value != selected else { return }
        selected = value
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        updateVisual(animated: true)
        onSelect?(value)
    }

    func setSelected(_ value: Int) {
        selected = value
        updateVisual(animated: false)
    }

    private func updateVisual(animated: Bool) {
        for pip in pips {
            let isOn = pip.tag == selected
            let scale: CGFloat = isOn ? 1.3 : 1.0
            let borderColor = isOn ? green.cgColor : UIColor.systemGray4.cgColor
            let bg = isOn ? green : UIColor.systemGray6

            let apply = {
                pip.backgroundColor = bg
                pip.layer.borderColor = borderColor
                pip.transform = CGAffineTransform(scaleX: scale, y: scale)
            }

            if animated {
                UIView.animate(withDuration: 0.25,
                               delay: 0,
                               usingSpringWithDamping: 0.55,
                               initialSpringVelocity: 0.8,
                               options: [],
                               animations: apply)
            } else {
                apply()
            }
        }
    }
}

// MARK: - WriteReviewViewController

final class WriteReviewViewController: UIViewController {

    // MARK: - Input
    private let classDocID: String
    private let courseName: String
    private let prefillTerm: String
    private let existingReview: CourseReview?
    var onSubmitted: (() -> Void)?

    // MARK: - Rating views
    private let kindnessRating = PipRatingView(leftText: "厳しい", rightText: "優しい")
    private let difficultyRating = PipRatingView(leftText: "鬼単", rightText: "楽単")

    // MARK: - UI
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let commentView = UITextView()
    private let charCountLabel = UILabel()
    private let placeholderLabel = UILabel()
    private let submitButton = UIButton(type: .system)
    private let maxComment = 150

    // MARK: - Init

    init(classDocID: String, courseName: String, prefillTerm: String, existing: CourseReview? = nil) {
        self.classDocID = classDocID
        self.courseName = courseName
        self.prefillTerm = prefillTerm
        self.existingReview = existing
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "授業レビュー"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(dismissSelf))
        buildLayout()
        setupKeyboardHandling()
        prefillIfNeeded()
        refreshSubmitState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
    }

    private func setupKeyboardHandling() {
        // 完了ボタン付きツールバー
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "完了", style: .done, target: self, action: #selector(dismissKeyboard))
        toolbar.items = [flex, done]
        commentView.inputAccessoryView = toolbar

        // キーボード表示/非表示でスクロール追従
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func dismissKeyboard() {
        commentView.resignFirstResponder()
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        guard let info = note.userInfo,
              let kbFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
              let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        let inset = kbFrame.height - view.safeAreaInsets.bottom
        UIView.animate(withDuration: duration,
                       delay: 0,
                       options: UIView.AnimationOptions(rawValue: curve << 16)) {
            self.scroll.contentInset.bottom = inset
            self.scroll.verticalScrollIndicatorInsets.bottom = inset
        }
        // コメント欄が隠れないようスクロール
        DispatchQueue.main.async {
            let rect = self.commentView.convert(self.commentView.bounds, to: self.scroll)
            self.scroll.scrollRectToVisible(rect.insetBy(dx: 0, dy: -12), animated: true)
        }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        guard let info = note.userInfo,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
              let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        UIView.animate(withDuration: duration,
                       delay: 0,
                       options: UIView.AnimationOptions(rawValue: curve << 16)) {
            self.scroll.contentInset.bottom = 0
            self.scroll.verticalScrollIndicatorInsets.bottom = 0
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32)
        ])

        // 授業名
        let nameLabel = UILabel()
        nameLabel.text = courseName
        nameLabel.font = .systemFont(ofSize: 17, weight: .bold)
        nameLabel.numberOfLines = 2
        stack.addArrangedSubview(nameLabel)

        // 先生の優しさ
        stack.addArrangedSubview(makeCard(title: "先生の優しさ", ratingView: kindnessRating))

        // 単位取得難易度
        stack.addArrangedSubview(makeCard(title: "単位取得難易度", ratingView: difficultyRating))

        // コメント
        stack.addArrangedSubview(makeCommentCard())

        // 送信ボタン
        var cfg = UIButton.Configuration.filled()
        cfg.title = "送信する"
        cfg.baseBackgroundColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .large
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0)
        submitButton.configuration = cfg
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        stack.addArrangedSubview(submitButton)

        kindnessRating.onSelect   = { [weak self] _ in self?.refreshSubmitState() }
        difficultyRating.onSelect = { [weak self] _ in self?.refreshSubmitState() }
    }

    private func makeCard(title: String, ratingView: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 14
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.05
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.layer.shadowRadius = 6

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel

        let inner = UIStackView(arrangedSubviews: [titleLabel, ratingView])
        inner.axis = .vertical
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    private func makeCommentCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 14
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.05
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.layer.shadowRadius = 6

        let titleLabel = UILabel()
        titleLabel.text = "一言コメント（任意・\(maxComment)字以内）"
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel

        commentView.font = .systemFont(ofSize: 15)
        commentView.backgroundColor = UIColor.secondarySystemBackground
        commentView.layer.cornerRadius = 10
        commentView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        commentView.delegate = self
        commentView.heightAnchor.constraint(equalToConstant: 90).isActive = true

        // プレースホルダー
        placeholderLabel.text = "例）テスト前だけ出ておけばOK。\n板書多いので写真撮っておくと便利。"
        placeholderLabel.font = .systemFont(ofSize: 15)
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        commentView.addSubview(placeholderLabel)
        // frameLayoutGuide で表示幅に合わせてtrailingを制約する
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: commentView.topAnchor, constant: 10),
            placeholderLabel.leadingAnchor.constraint(equalTo: commentView.frameLayoutGuide.leadingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(equalTo: commentView.frameLayoutGuide.trailingAnchor, constant: -12)
        ])

        charCountLabel.text = "0 / \(maxComment)"
        charCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        charCountLabel.textColor = .tertiaryLabel
        charCountLabel.textAlignment = .right

        let inner = UIStackView(arrangedSubviews: [titleLabel, commentView, charCountLabel])
        inner.axis = .vertical
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    // MARK: - Prefill

    private func prefillIfNeeded() {
        guard let r = existingReview else { return }
        title = "レビューを編集"
        kindnessRating.setSelected(r.teacherKindness)
        difficultyRating.setSelected(r.creditDifficulty)
        if !r.comment.isEmpty {
            commentView.text = r.comment
            placeholderLabel.isHidden = true
            charCountLabel.text = "\(r.comment.count) / \(maxComment)"
        }
        var cfg = submitButton.configuration
        cfg?.title = "更新する"
        submitButton.configuration = cfg
    }

    // MARK: - State

    private func refreshSubmitState() {
        let ready = kindnessRating.selected > 0 && difficultyRating.selected > 0
        UIView.animate(withDuration: 0.2) {
            self.submitButton.alpha = ready ? 1 : 0.45
        }
        submitButton.isEnabled = ready
    }

    // MARK: - Submit

    @objc private func submitTapped() {
        guard let uid = Auth.auth().currentUser?.uid else {
            showAlert("ログインが必要です"); return
        }
        let comment = commentView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let review = CourseReview(
            uid: uid,
            teacherKindness: kindnessRating.selected,
            creditDifficulty: difficultyRating.selected,
            comment: comment,
            term: prefillTerm
        )
        submitButton.isEnabled = false
        ReviewService.shared.saveReview(review, courseCode: classDocID) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    WriteReviewViewController.markSubmitted(courseCode: self?.classDocID ?? "")
                    self?.onSubmitted?()
                    self?.dismiss(animated: true)
                case .failure(let error):
                    self?.submitButton.isEnabled = true
                    self?.showAlert("送信に失敗しました: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Submitted state

    static func hasSubmitted(courseCode: String) -> Bool {
        UserDefaults.standard.bool(forKey: "reviewSubmitted.\(courseCode)")
    }

    static func markSubmitted(courseCode: String) {
        UserDefaults.standard.set(true, forKey: "reviewSubmitted.\(courseCode)")
    }

    // MARK: - Helpers

    private func showAlert(_ message: String) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "OK", style: .default))
        present(ac, animated: true)
    }

    @objc private func dismissSelf() { dismiss(animated: true) }
}

// MARK: - UITextViewDelegate

extension WriteReviewViewController: UITextViewDelegate {
    func textView(_ textView: UITextView,
                  shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        let next = (textView.text as NSString).replacingCharacters(in: range, with: text)
        return next.count <= maxComment
    }

    func textViewDidChange(_ textView: UITextView) {
        let count = textView.text.count
        charCountLabel.text = "\(count) / \(maxComment)"
        charCountLabel.textColor = count > maxComment ? .systemRed : .tertiaryLabel
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
}
