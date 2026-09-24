//
//  ReactionPaperViewController.swift
//  Aogaku
//
//  授業AI: その日の授業内容と資料からリアクションペーパーの下書きを作る
//

import UIKit

final class ReactionPaperViewController: UIViewController {

    private let transcript: String
    private let photoText: String
    private let syllabusOverview: String

    private let scroll = UIScrollView()
    private let assignmentLabel = UILabel()
    private let assignmentField = UITextView()
    private let notesLabel = UILabel()
    private let notesField = UITextView()
    private let lengthLabel = UILabel()
    private let lengthStepper = UIStepper()
    private let generateButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let resultView = UITextView()
    private let copyButton = UIButton(type: .system)
    private let disclaimerLabel = UILabel()

    private var targetLength: Int = 400 {
        didSet { lengthLabel.text = "\(targetLength)字" }
    }

    init(transcript: String, photoText: String, syllabusOverview: String) {
        self.transcript = transcript
        self.photoText = photoText
        self.syllabusOverview = syllabusOverview
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "リアペを作る"
        view.backgroundColor = .systemBackground
        buildLayout()

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(tap)
    }

    private func buildLayout() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        assignmentLabel.text = "課題の指示(任意)"
        assignmentLabel.font = .systemFont(ofSize: 13, weight: .medium)
        assignmentLabel.textColor = .secondaryLabel

        assignmentField.font = .systemFont(ofSize: 15)
        assignmentField.layer.cornerRadius = 8
        assignmentField.layer.borderWidth = 1
        assignmentField.layer.borderColor = UIColor.separator.cgColor
        assignmentField.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        notesLabel.text = "自分の感想・入れたい視点(任意)"
        notesLabel.font = .systemFont(ofSize: 13, weight: .medium)
        notesLabel.textColor = .secondaryLabel

        notesField.font = .systemFont(ofSize: 15)
        notesField.layer.cornerRadius = 8
        notesField.layer.borderWidth = 1
        notesField.layer.borderColor = UIColor.separator.cgColor
        notesField.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        lengthLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        lengthLabel.textAlignment = .right
        lengthLabel.text = "\(targetLength)字"

        lengthStepper.minimumValue = 100
        lengthStepper.maximumValue = 2000
        lengthStepper.stepValue = 50
        lengthStepper.value = Double(targetLength)
        lengthStepper.addTarget(self, action: #selector(stepperChanged), for: .valueChanged)

        var generateConfig = UIButton.Configuration.filled()
        generateConfig.title = "この内容で作る"
        generateConfig.image = UIImage(systemName: "sparkles")
        generateConfig.imagePadding = 8
        generateConfig.baseBackgroundColor = HackColors.accent
        generateConfig.baseForegroundColor = .white
        generateConfig.cornerStyle = .medium
        generateConfig.buttonSize = .large
        generateButton.configuration = generateConfig
        generateButton.addTarget(self, action: #selector(generateTapped), for: .touchUpInside)

        spinner.hidesWhenStopped = true

        resultView.isEditable = true
        resultView.font = .systemFont(ofSize: 15)
        resultView.layer.cornerRadius = 8
        resultView.backgroundColor = .secondarySystemBackground
        resultView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        resultView.isHidden = true

        var copyConfig = UIButton.Configuration.gray()
        copyConfig.title = "コピー"
        copyConfig.image = UIImage(systemName: "doc.on.doc")
        copyConfig.imagePadding = 6
        copyButton.configuration = copyConfig
        copyButton.isHidden = true
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        disclaimerLabel.font = .systemFont(ofSize: 12)
        disclaimerLabel.textColor = .tertiaryLabel
        disclaimerLabel.numberOfLines = 0
        disclaimerLabel.textAlignment = .center
        disclaimerLabel.text = "生成結果は自動生成のたたき台です。内容を確認したうえでご利用ください。そのまま提出しないでください。"

        let lengthTitleLabel = UILabel()
        lengthTitleLabel.text = "文字数"
        lengthTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let lengthRow = UIStackView(arrangedSubviews: [lengthTitleLabel, UIView(), lengthLabel, lengthStepper])
        lengthRow.axis = .horizontal
        lengthRow.alignment = .center
        lengthRow.spacing = 10

        let stack = UIStackView(arrangedSubviews: [
            assignmentLabel, assignmentField,
            notesLabel, notesField,
            lengthRow, generateButton, spinner, resultView, copyButton, disclaimerLabel
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.setCustomSpacing(20, after: notesField)
        stack.setCustomSpacing(16, after: lengthRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        [assignmentField, notesField, generateButton, resultView, lengthStepper].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),

            assignmentField.heightAnchor.constraint(equalToConstant: 70),
            notesField.heightAnchor.constraint(equalToConstant: 100),
            resultView.heightAnchor.constraint(equalToConstant: 260)
        ])
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func stepperChanged() {
        targetLength = Int(lengthStepper.value)
    }

    @objc private func generateTapped() {
        view.endEditing(true)
        generateButton.isEnabled = false
        spinner.startAnimating()
        resultView.isHidden = true
        copyButton.isHidden = true

        Task {
            do {
                let text = try await ReactionPaperService.shared.generate(
                    transcript: transcript,
                    photoText: photoText,
                    syllabusOverview: syllabusOverview,
                    assignmentInstructions: assignmentField.text,
                    personalNotes: notesField.text,
                    targetLength: targetLength
                )
                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.generateButton.isEnabled = true
                    self.resultView.text = text
                    self.resultView.isHidden = false
                    self.copyButton.isHidden = false
                }
            } catch {
                await MainActor.run {
                    self.spinner.stopAnimating()
                    self.generateButton.isEnabled = true
                    let alert = UIAlertController(title: "生成に失敗しました", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = resultView.text
    }
}
