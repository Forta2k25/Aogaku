import UIKit

/// 補講日を選ぶ小さなシート。
final class NoteExtraDatePickerViewController: UIViewController {
    var onPick: ((Date) -> Void)?
    private let picker = UIDatePicker()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "補講日を追加"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .inline
        picker.locale = Locale(identifier: "ja_JP")
        picker.tintColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        picker.translatesAutoresizingMaskIntoConstraints = false

        var cfg = UIButton.Configuration.filled()
        cfg.title = "追加"
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = UIColor(red: 0/255, green: 120/255, blue: 87/255, alpha: 1)
        cfg.baseForegroundColor = .white
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)
        let add = UIButton(configuration: cfg)
        add.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        add.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(title)
        view.addSubview(picker)
        view.addSubview(add)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            picker.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            add.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            add.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            add.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @objc private func addTapped() {
        let date = picker.date
        dismiss(animated: true) { [onPick] in onPick?(date) }
    }
}
