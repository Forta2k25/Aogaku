//
//  MemoTaskViewController.swift
//  Aogaku
//
//  Created by shu m on 2025/10/01.
//
import UIKit

fileprivate struct TaskItem: Codable {
    var title: String
    var due: Date?
    var done: Bool
}

final class MemoTaskViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // MARK: Inputs
    private let courseId: String
    private let courseTitle: String

    // MARK: Storage Keys
    private var memoKey: String { "memo.\(courseId)" }
    private var tasksKey: String { "tasks.\(courseId)" }

    // MARK: UI
    private let scroll = UIScrollView()
    private let stack  = UIStackView()
    private let memoLabel = UILabel()
    private let memoView  = UITextView()
    private let addTaskButton = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: Model
    private var tasks: [TaskItem] = []

    // MARK: Init
    init(courseId: String, courseTitle: String) {
        self.courseId = courseId
        self.courseTitle = courseTitle
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "メモ・課題"

        // ナビバーに閉じるボタン（モーダル時）
        if presentingViewController != nil && navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self, action: #selector(closeSelf)
            )
        }

        setupLayout()
        loadMemo()
        loadTasks()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveMemo() // 自動保存
    }

    // MARK: UI Build
    private func setupLayout() {
        // Scroll + Stack
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
        ])

        // メモラベル
        memoLabel.text = "メモ（\(courseTitle)）"
        memoLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(memoLabel)

        // メモ
        memoView.font = .systemFont(ofSize: 16)
        memoView.backgroundColor = .secondarySystemBackground
        memoView.layer.cornerRadius = 12
        memoView.isScrollEnabled = false
        memoView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        stack.addArrangedSubview(memoView)
        memoView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        // 「課題を追加」ボタン
        var addCfg = UIButton.Configuration.filled()
        addCfg.title = "課題を追加"
        addCfg.cornerStyle = .large
        addCfg.contentInsets = .init(top: 10, leading: 14, bottom: 10, trailing: 14)
        addTaskButton.configuration = addCfg
        addTaskButton.addTarget(self, action: #selector(addTaskTapped), for: .touchUpInside)
        stack.addArrangedSubview(addTaskButton)

        // 課題テーブル
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.isScrollEnabled = false
        table.layer.cornerRadius = 12
        stack.addArrangedSubview(table)
        table.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    }

    // MARK: Actions
    @objc private func closeSelf() { dismiss(animated: true) }

    @objc private func addTaskTapped() {
        let ac = UIAlertController(title: "課題を追加", message: nil, preferredStyle: .alert)
        ac.addTextField { tf in
            tf.placeholder = "タイトル（例: レポート提出）"
        }
        // 期日ピッカー
        let picker = UIDatePicker()
        picker.datePickerMode = .dateAndTime
        if #available(iOS 13.4, *) { picker.preferredDatePickerStyle = .wheels }

        ac.view.addSubview(picker)
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: ac.view.topAnchor, constant: 90),
            picker.leadingAnchor.constraint(equalTo: ac.view.leadingAnchor, constant: 16),
            picker.trailingAnchor.constraint(equalTo: ac.view.trailingAnchor, constant: -16),
            picker.bottomAnchor.constraint(equalTo: ac.view.bottomAnchor, constant: -60)
        ])

        ac.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        ac.addAction(UIAlertAction(title: "追加", style: .default, handler: { [weak self, weak ac] _ in
            guard let self = self else { return }
            let title = ac?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return }
            self.tasks.append(TaskItem(title: title, due: picker.date, done: false))
            self.saveTasks()
            self.reloadTableHeight()
        }))
        present(ac, animated: true)
    }

    // MARK: Table
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tasks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = tasks[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = UIListContentConfiguration.valueCell()
        cfg.text = item.title
        if let d = item.due {
            let f = DateFormatter()
            f.dateFormat = "M/d(E) HH:mm"
            cfg.secondaryText = "期限: " + f.string(from: d)
        } else {
            cfg.secondaryText = nil
        }
        cell.contentConfiguration = cfg
        cell.accessoryType = item.done ? .checkmark : .none
        return cell
    }

    // タップで完了トグル、左スワイプで削除
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        tasks[indexPath.row].done.toggle()
        saveTasks()
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
                   -> UISwipeActionsConfiguration? {
        let del = UIContextualAction(style: .destructive, title: "削除") { [weak self] _,_,done in
            self?.tasks.remove(at: indexPath.row)
            self?.saveTasks()
            self?.reloadTableHeight()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [del])
    }

    // テーブル高さを中身に合わせて更新
    private func reloadTableHeight() {
        table.reloadData()
        table.layoutIfNeeded()
        let h = min(max(table.contentSize.height, 120), 600)
        if let c = (table.constraints.first { $0.firstAttribute == .height }) {
            c.constant = h
        }
    }

    // MARK: Persistence
    private func saveMemo() {
        let text = memoView.text ?? ""
        UserDefaults.standard.set(text, forKey: memoKey)
    }
    private func loadMemo() {
        memoView.text = UserDefaults.standard.string(forKey: memoKey) ?? ""
    }
    private func saveTasks() {
        let data = try? JSONEncoder().encode(tasks)
        UserDefaults.standard.set(data, forKey: tasksKey)
    }
    private func loadTasks() {
        if let data = UserDefaults.standard.data(forKey: tasksKey),
           let arr = try? JSONDecoder().decode([TaskItem].self, from: data) {
            tasks = arr
        }
        reloadTableHeight()
    }
}
