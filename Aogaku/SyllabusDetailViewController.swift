import UIKit
import FirebaseFirestore

final class SyllabusDetailViewController: UIViewController {

    // 呼び出し側から受け取る
    var docID: String?
    var initialTitle: String?
    var initialTeacher: String?
    var initialCredit: String?

    // --- Storyboard Outlets ---
    // タイトルは UITextView（長い名前対応）
    @IBOutlet weak var titleTextView: UITextView!

    // ボタン（画像は Storyboard 側で Normal/Selected を設定）
    @IBOutlet weak var addButton: UIButton!
    @IBOutlet weak var bookmarkButton: UIButton!
    @IBOutlet weak var closeButton: UIButton!

    // 詳細表示
    @IBOutlet weak var codeLabel: UILabel!
    @IBOutlet weak var roomOrURLTextView: UITextView!
    @IBOutlet weak var teacherLabel: UILabel!
    @IBOutlet weak var creditLabel: UILabel!

    // 簡易保存（必要に応じて Firestore の /users/{uid}… に置き換え可）
    private let plannedKey = "plannedClassIDs"
    private let favoriteKey = "favoriteClassIDs"

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- タイトルTextViewのスタイル（背景透明・白文字・20pt Bold） ---
        titleTextView?.isEditable = false
        titleTextView?.isSelectable = false
        titleTextView?.isScrollEnabled = false           // コンテナ（親ScrollView）に任せる
        titleTextView?.textContainerInset = .zero
        titleTextView?.textContainer.lineFragmentPadding = 0
        titleTextView?.backgroundColor = .clear
        titleTextView?.isOpaque = false
        titleTextView?.textColor = .white
        titleTextView?.font = .boldSystemFont(ofSize: 20)
        titleTextView?.text = (initialTitle?.isEmpty == false) ? initialTitle! : "科目名"

        // そのほかの表示
        teacherLabel?.text = initialTeacher ?? ""
        if let c = initialCredit, !c.isEmpty { creditLabel?.text = "\(c)単位" } else { creditLabel?.text = "" }

        roomOrURLTextView?.isEditable = false
        roomOrURLTextView?.dataDetectorTypes = [.link, .address]
        roomOrURLTextView?.textContainerInset = .zero
        roomOrURLTextView?.textContainer.lineFragmentPadding = 0

        // アイコンはStoryboard任せ。状態だけ反映
        refreshButtons()

        // docID が無ければ閉じる
        guard let id = docID, !id.isEmpty else {
            print("❌ detail open failed: docID is nil/empty")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.dismiss(animated: true) }
            return
        }
        fetchDetail(docID: id)
    }

    // Firestore 読み込み
    private func fetchDetail(docID: String) {
        Firestore.firestore().collection("classes").document(docID).getDocument { [weak self] snap, err in
            guard let self = self else { return }
            if let err = err { print("❌ detail fetch error:", err); return }
            guard let data = snap?.data() else { print("❌ detail: document not found"); return }

            if let name = data["class_name"] as? String { self.titleTextView?.text = name }
            if let t = data["teacher_name"] as? String { self.teacherLabel?.text = t }
            if let c = data["credit"] as? Int {
                self.creditLabel?.text = "\(c)単位"
            } else if let cStr = data["credit"] as? String, !cStr.isEmpty {
                self.creditLabel?.text = "\(cStr)単位"
            }

            let code = (data["registration_number"] as? String)
                ?? (data["code"] as? String)
                ?? (data["class_code"] as? String)
                ?? (data["course_code"] as? String)
            self.codeLabel?.text = code ?? "-"

            let room = (data["room"] as? String) ?? (data["classroom"] as? String)
            let url = (data["url"] as? String) ?? (data["webex"] as? String) ?? (data["zoom"] as? String)
            if let urlStr = url, !urlStr.isEmpty {
                self.roomOrURLTextView?.text = urlStr
            } else if let r = room, !r.isEmpty {
                self.roomOrURLTextView?.text = r
            } else {
                self.roomOrURLTextView?.text = "-"
            }
        }
    }

    // MARK: - Buttons
    @IBAction func didTapClose(_ sender: Any) { dismiss(animated: true) }

    @IBAction func didTapAdd(_ sender: Any) {
        guard let id = docID, !id.isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: plannedKey) ?? [])
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Array(set), forKey: plannedKey)
        refreshButtons()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @IBAction func didTapBookmark(_ sender: Any) {
        guard let id = docID, !id.isEmpty else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? [])
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        UserDefaults.standard.set(Array(set), forKey: favoriteKey)
        refreshButtons()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func refreshButtons() {
        guard let id = docID, !id.isEmpty else {
            addButton?.isSelected = false
            bookmarkButton?.isSelected = false
            return
        }
        let planned = Set(UserDefaults.standard.stringArray(forKey: plannedKey) ?? []).contains(id)
        let favorite = Set(UserDefaults.standard.stringArray(forKey: favoriteKey) ?? []).contains(id)
        addButton?.isSelected = planned
        bookmarkButton?.isSelected = favorite
    }
}
