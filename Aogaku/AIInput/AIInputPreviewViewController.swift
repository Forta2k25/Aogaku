#if DEBUG
import UIKit

/// Reuses the real composer and durable store. Sample statuses never represent completed cloud work.
@MainActor
final class AIInputPreviewViewController: UITableViewController {
    private let context = AIInputContext(ownerUID: "local-ai-preview-v1", localCourseId: "local-preview-course", classDocId: nil,
                                         year: 2026, semester: "fall", dayID: 20732)
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AI入力・ローカル確認"
        let label = UILabel(); label.numberOfLines = 0; label.font = .systemFont(ofSize: 14); label.textAlignment = .center
        label.text = AppBackend.configurationError ?? "Firebase・広告・外部APIを起動しません。\n追加した資料はこの確認用アプリの端末内だけに保存します。"
        label.frame.size.height = 90; tableView.tableHeaderView = label
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { AppBackend.configurationError == nil ? 3 : 0 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let titles = ["AI入力画面を開く", "資料一覧・状態サンプル", "写真・PDFの確認用サンプルを作成"]
        let details = ["授業のAIタブ → 第N回 → ＋メニュー", "未送信・解析中・部分成功・失敗・共有の表示確認", "ローカル生成した資料をFilesで選べます"]
        cell.textLabel?.text = titles[indexPath.row]; cell.detailTextLabel?.text = details[indexPath.row]
        cell.accessoryType = .disclosureIndicator; cell.accessibilityIdentifier = "ai-preview-\(indexPath.row)"; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        do {
            switch indexPath.row {
            case 0:
                let course = Course(id: context.localCourseId, title: "AI入力確認用の授業", room: "ローカル", teacher: "確認用",
                                    credits: nil, campus: "青山", category: nil, syllabusURL: nil, term: "後期")
                let vc = CourseDetailViewController(course: course, location: SlotLocation(day: 1, period: 1), term: TermKey(year: 2026, semester: .fall),
                    showsAttendanceControls: false, allowsCourseManagement: false, showsEnrolledFriends: false, showsMoodleAssignments: false, showsLectureNotes: true)
                present(vc, animated: true)
            case 1:
                try seedStatuses()
                present(UINavigationController(rootViewController: SourceLibraryViewController(context: context, allDays: true)), animated: true)
            default:
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AIInputSamples")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let rect = CGRect(x: 0, y: 0, width: 600, height: 800)
                let draw = {
                    UIColor.white.setFill(); UIBezierPath(rect: rect).fill()
                    ("AI入力確認用の資料\n社会契約についてのメモ\nこれはローカル生成の架空資料です。" as NSString).draw(in: rect.insetBy(dx: 40, dy: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black])
                }
                let image = UIGraphicsImageRenderer(size: rect.size).image { _ in draw() }
                try image.jpegData(compressionQuality: 0.9)!.write(to: directory.appendingPathComponent("sample-photo.jpg"), options: .atomic)
                try UIGraphicsPDFRenderer(bounds: rect).pdfData { renderer in renderer.beginPage(); draw() }.write(to: directory.appendingPathComponent("sample-document.pdf"), options: .atomic)
                let alert = UIAlertController(title: "サンプルを作成しました", message: "Files → このiPhone内 → 青山ハック Dev → AIInputSamples。PDFは＋メニューから選択できます。写真はSimulatorの写真アプリへ追加して選択してください。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel)); present(alert, animated: true)
            }
        } catch {
            let alert = UIAlertController(title: "確認データを開けませんでした", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel)); present(alert, animated: true)
        }
    }
    private func seedStatuses() throws {
        let store = try SourceIngestionService.shared.store(uid: context.ownerUID)
        for status in ["draft", "queued", "uploading", "extracting", "indexing", "ready", "partial_ready", "failed"] {
            let title = "【表示サンプル】\(status)"
            var source: AIStoredSource
            if let existing = store.ledger.sources.first(where: { $0.title == title }) {
                source = existing
            } else {
                source = try store.stage(context: context, kind: .note, title: title, mime: "text/plain", text: "表示サンプル: \(status)。クラウドで解析した資料ではありません。")
            }
            source.remote = nil
            source.lastError = nil
            source.wantsDeletion = false
            source.submitted = status != "draft"
            source.localState = ["draft", "queued", "uploading"].contains(status) ? status : "uploaded"
            if source.localState == "uploaded" {
                source.remote = AIRemoteSource(sourceId: "preview-\(source.id)", sourceType: "note", title: title,
                    courseOfferingId: "preview-course", lectureId: "preview-lecture", dayID: context.dayID, status: status,
                    coverage: status == "partial_ready" ? AISourceCoverage(totalUnits: 2, processedUnits: 1, failedUnits: [2]) : nil,
                    error: status == "failed" ? AISourceFailure(code: "PREVIEW", retryable: true) : nil,
                    rawVisibility: "private", knowledgeVisibility: "private")
            }
            try store.update(source)
        }
    }
}
#else
import UIKit
final class AIInputPreviewViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let label = UILabel(frame: view.bounds); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0; label.textAlignment = .center; label.text = AppBackend.configurationError; view.addSubview(label)
    }
}
#endif
