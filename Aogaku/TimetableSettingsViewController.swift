import UIKit

final class TimetableSettingsViewController: UIViewController {

    private var settings = TimetableSettings.load()

    private let periodsSeg = UISegmentedControl(items: ["5", "6", "7"])
    private let daysSeg = UISegmentedControl(items: ["平日のみ", "平日＋土"])

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "表示設定"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "閉じる", style: .plain, target: self, action: #selector(close)
        )

        // 初期値
        periodsSeg.selectedSegmentIndex = [5,6,7].firstIndex(of: settings.periods) ?? 0
        daysSeg.selectedSegmentIndex = settings.includeSaturday ? 1 : 0

        periodsSeg.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        daysSeg.addTarget(self, action: #selector(valueChanged), for: .valueChanged)

        // 簡単レイアウト
        let stack = UIStackView(arrangedSubviews: [
            labeled("時限数", periodsSeg),
            labeled("曜日", daysSeg),
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }

    private func labeled(_ title: String, _ control: UIView) -> UIStackView {
        let l = UILabel()
        l.text = title
        l.font = .systemFont(ofSize: 14, weight: .semibold)
        let v = UIStackView(arrangedSubviews: [l, control])
        v.axis = .vertical
        v.spacing = 8
        return v
    }

    @objc private func valueChanged() {
        let ps = [5,6,7][periodsSeg.selectedSegmentIndex]
        let sat = (daysSeg.selectedSegmentIndex == 1)
        settings.periods = ps
        settings.includeSaturday = sat
        settings.save()

        // timetable に通知
        NotificationCenter.default.post(name: .timetableSettingsChanged, object: nil)
    }

    @objc private func close() { dismiss(animated: true) }
}
