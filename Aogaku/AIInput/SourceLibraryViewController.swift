import UIKit
import QuickLook
import FirebaseAuth

@MainActor
final class SourceLibraryViewController: UITableViewController, QLPreviewControllerDataSource {
    private let context: AIInputContext
    private let allDays: Bool
    private var sources: [AIStoredSource] = []
    private var remoteSources: [AIRemoteSource] = []
    private var nextCursor: String?
    private var polling: Task<Void, Never>?
    private var previewURL: URL?
    init(context: AIInputContext, allDays: Bool) {
        self.context = context; self.allDays = allDays
        super.init(style: .insetGrouped)
        title = allDays ? "授業の資料" : "この回の資料"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .aiSourcesChanged, object: nil)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "source")
        if AppBackend.isOffline {
            let label = UILabel(); label.text = "通信なし · 状態サンプルの共有は表示確認のみ"; label.font = .systemFont(ofSize: 12)
            label.textAlignment = .center; label.numberOfLines = 2; label.frame.size.height = 45
            tableView.tableHeaderView = label
        }
        reload()
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshAll), for: .valueChanged)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        SourceIngestionService.shared.resume(uid: context.ownerUID)
        Task { await loadRemote(reset: true) }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await SourceIngestionService.shared.refresh(uid: context.ownerUID)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); polling?.cancel(); polling = nil }
    @objc private func close() { dismiss(animated: true) }
    @objc private func reload() {
        do {
            guard AppBackend.currentUID == context.ownerUID else { sources = []; remoteSources = []; nextCursor = nil; tableView.reloadData(); return }
            sources = try SourceIngestionService.shared.store(uid: context.ownerUID).sources(context: context, includeOtherDays: allDays).sorted { $0.createdAt > $1.createdAt }
            tableView.reloadData()
            let empty = UILabel(); empty.text = "資料はまだありません"; empty.textAlignment = .center; empty.textColor = .secondaryLabel
            tableView.backgroundView = sources.isEmpty && remoteSources.isEmpty ? empty : nil
        } catch { showError(error) }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "この端末の資料" : section == 1 && !remoteSources.isEmpty ? "クラウドの資料・共有資料" : nil
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? sources.count : section == 1 ? remoteSources.count : nextCursor == nil ? 0 : 1
    }
    @objc private func refreshAll() {
        SourceIngestionService.shared.resume(uid: context.ownerUID)
        Task { await loadRemote(reset: true); refreshControl?.endRefreshing() }
    }
    private func loadRemote(reset: Bool) async {
        guard !AppBackend.isOffline else { return }
        do {
            var request: [String: Any] = ["context": context.request, "onlyLecture": !allDays]
            if !reset, let nextCursor { request["after"] = nextCursor }
            let result = try await SourceIngestionService.shared.call("aiListSources", data: request, uid: context.ownerUID)
            let values = result["items"] as? [[String: Any]] ?? []
            let page = try JSONDecoder().decode([AIRemoteSource].self, from: JSONSerialization.data(withJSONObject: values))
            let localIDs = Set(sources.compactMap { $0.remote?.sourceId })
            if reset { remoteSources = [] }
            let existingIDs = Set(remoteSources.map(\.sourceId))
            remoteSources.append(contentsOf: page.filter { !localIDs.contains($0.sourceId) && !existingIDs.contains($0.sourceId) })
            nextCursor = result["nextCursor"] as? String
            reload()
        } catch { if remoteSources.isEmpty { /* Local files remain usable while offline. */ } }
    }
    private func showEvidence(_ source: AIRemoteSource) {
        Task {
            do {
                let result = try await SourceIngestionService.shared.call("aiGetEvidence", data: ["sourceId": source.sourceId], uid: context.ownerUID)
                let items = result["items"] as? [[String: Any]] ?? []
                let text = items.map { item -> String in
                    let locator = item["locator"] as? [String: Any] ?? [:]
                    let position: String
                    if let page = locator["pageNumber"] as? Int { position = "p.\(page)" }
                    else if let ms = locator["startMs"] as? Int { position = "\(ms / 60000):\(String(format: "%02d", (ms / 1000) % 60))" }
                    else { position = "" }
                    return "\(position)\n\(item["text"] as? String ?? "")"
                }.joined(separator: "\n\n")
                let vc = UIViewController(); vc.title = source.title
                let view = UITextView(); view.isEditable = false; view.font = .systemFont(ofSize: 16)
                view.text = text.isEmpty ? "利用できる抽出本文はまだありません" : text + (result["nextCursor"] is String ? "\n\n表示は先頭20件までです。" : "")
                vc.view = view; navigationController?.pushViewController(vc, animated: true)
            } catch { showError(error) }
        }
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 2 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.textLabel?.text = "さらに読み込む"; return cell
        }
        if indexPath.section == 1 {
            let source = remoteSources[indexPath.row]
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = source.title; cell.detailTextLabel?.text = source.status == "ready" ? "抽出本文を見る" : source.status == "partial_ready" ? "一部利用可能" : "処理中・利用できない資料"
            cell.accessoryType = .disclosureIndicator; return cell
        }
        let source = sources[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "source", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = source.title
        content.secondaryText = "\(source.statusText)\n\(source.remote?.knowledgeVisibility == "course" ? "授業内共有" : "自分のみ")"
        content.image = UIImage(systemName: source.kind == .image ? "photo" : source.kind == .audio ? "waveform" : "doc.text")
        cell.contentConfiguration = content; cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard AppBackend.currentUID == context.ownerUID else { reload(); return }
        if indexPath.section == 2 { Task { await loadRemote(reset: false) }; return }
        if indexPath.section == 1 { showEvidence(remoteSources[indexPath.row]); return }
        let source = sources[indexPath.row]
        let alert = UIAlertController(title: source.title, message: source.statusText, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "内容を見る", style: .default) { [weak self] _ in self?.preview(source) })
        if !source.submitted {
            alert.addAction(UIAlertAction(title: "AIに追加", style: .default) { [weak self] _ in
                do {
                    let store = try SourceIngestionService.shared.store(uid: source.context.ownerUID)
                    let snapshot = AIChatSnapshot(id: UUID().uuidString, context: source.context, kind: source.kind.rawValue, text: source.text, sourceIDs: [source.id], createdAt: Date())
                    try store.submit(context: source.context, snapshots: [snapshot]); SourceIngestionService.shared.resume(uid: source.context.ownerUID)
                    self?.reload()
                } catch { self?.showError(error) }
            })
        } else if source.localState == "failed" || ["failed", "partial_ready"].contains(source.remote?.status ?? "") {
            alert.addAction(UIAlertAction(title: "再試行", style: .default) { [weak self] _ in
                Task { do { try await SourceIngestionService.shared.retry(source) } catch { self?.showError(error) } }
            })
        }
        if source.remote != nil {
            let shared = source.remote?.knowledgeVisibility == "course"
            alert.addAction(UIAlertAction(title: shared ? "自分のみに戻す" : "この授業に共有", style: .default) { [weak self] _ in
                Task { do { try await SourceIngestionService.shared.setShared(source, shared: !shared) } catch { self?.showError(error) } }
            })
        }
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            Task { do { try await SourceIngestionService.shared.delete(source); self?.reload() } catch { self?.showError(error) } }
        })
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(alert, animated: true)
    }
    private func preview(_ source: AIStoredSource) {
        guard AppBackend.currentUID == context.ownerUID else { reload(); return }
        if let text = source.text {
            let alert = UIAlertController(title: source.title, message: text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "閉じる", style: .cancel)); present(alert, animated: true); return
        }
        do {
            guard let url = try SourceIngestionService.shared.store(uid: context.ownerUID).fileURL(source) else { return }
            previewURL = url
            let vc = QLPreviewController(); vc.dataSource = self; present(vc, animated: true)
        } catch { showError(error) }
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewURL! as NSURL }
    private func showError(_ error: Error) {
        let vc = UIAlertController(title: "資料を確認してください", message: error.localizedDescription, preferredStyle: .alert)
        vc.addAction(UIAlertAction(title: "閉じる", style: .cancel)); present(vc, animated: true)
    }
}
