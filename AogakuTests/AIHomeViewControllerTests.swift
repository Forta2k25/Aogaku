import XCTest
import UIKit
@testable import Aogaku

@MainActor
final class AIHomeViewControllerTests: XCTestCase {
    private var windows: [UIWindow] = []
    private let uuidReading = "11111111-1111-4111-8111-111111111111"
    private let uuidBible = "22222222-2222-4222-8222-222222222222"

    private func course(_ id: String, _ title: String, uuid: String) -> Course {
        var course = Course(id: id, title: title, room: "", teacher: "", credits: 2, campus: "青山", category: nil, syllabusURL: nil, term: nil)
        course.localCourseUUID = uuid
        return course
    }
    private func makeEntries() -> [QuickAskCourse] {
        [QuickAskCourse(course: course("reading", "Reading II", uuid: uuidReading), location: SlotLocation(day: 1, period: 2)),
         QuickAskCourse(course: course("bible", "旧約聖書と人間", uuid: uuidBible), location: SlotLocation(day: 1, period: 3))]
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents(); parts.year = 2026; parts.month = 10; parts.day = day; parts.hour = hour; parts.minute = minute
        return QuickAskRouting.jst.date(from: parts)!
    }
    private func makeHome(now: Date, entries: [QuickAskCourse]? = nil) -> AIHomeViewController {
        let home = AIHomeViewController()
        let list = entries ?? makeEntries()
        home.entriesProvider = { (list, TermKey(year: 2026, semester: .fall)) }
        home.now = { now }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = home; window.makeKeyAndVisible(); windows.append(window)
        home.loadViewIfNeeded(); home.viewWillAppear(false)
        return home
    }
    private func chipTitle(_ home: AIHomeViewController) -> String {
        guard let attributed = home.chipButton.configuration?.attributedTitle else { return "" }
        return String(attributed.characters)
    }

    func testDuringAClassTheChipShowsThatClassAndTheQuestionGoesStraightToItsChat() {
        let home = makeHome(now: date(20, 11, 30))   // 火曜 11:30 = Reading II の授業中
        XCTAssertEqual(home.selected?.course.id, "reading")
        XCTAssertEqual(chipTitle(home), "Reading II · 授業中")
        var opened: [(QuickAskCourse, Int, String, Int)] = []
        home.chatOpener = { entry, day, text, photos in opened.append((entry, day, text, photos.count)) }
        XCTAssertFalse(home.sendButton.isEnabled, "何も入力していないときは、送れない")
        home.textView.text = "この単語の意味は?"
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: home.textView)
        XCTAssertTrue(home.sendButton.isEnabled)
        home.sendTapped()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0.course.id, "reading"); XCTAssertEqual(opened.first?.2, "この単語の意味は?"); XCTAssertEqual(opened.first?.3, 0)
        XCTAssertLessThanOrEqual(opened.first?.1 ?? Int.max, QuickAskRouting.dayID(of: date(20, 11, 30)), "回は、今日か、直近の授業日")
        XCTAssertEqual(home.textView.text, "", "送ったら、入力欄は空に戻る")
    }

    func testOutsideClassTimeNothingIsPickedAndSendingAsksThePredictorThenLetsTheUserChoose() async throws {
        let home = makeHome(now: date(20, 20, 0))   // 火曜の夜: 授業の付近ではない
        XCTAssertNil(home.selected)
        XCTAssertTrue(chipTitle(home).hasPrefix("授業を選ぶ"))
        var asked: [String] = []
        home.predictor = { question, _, entries, now in
            asked.append(question)
            let bible = entries.first { $0.course.id == "bible" }!, reading = entries.first { $0.course.id == "reading" }!
            return QuickAskPredictor.Prediction(ordered: [bible, reading], candidates: [QuickAskPredictor.Candidate(entry: bible, confidence: 0.9, reason: "ダビデ")])
        }
        var opened: [String] = []
        home.chatOpener = { entry, _, _, _ in opened.append(entry.course.id) }
        home.textView.text = "ダビデ王ってどんな人?"
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: home.textView)
        home.sendTapped()
        for _ in 0..<100 where home.presentedViewController == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(asked, ["ダビデ王ってどんな人?"])
        let sheet = try XCTUnwrap(home.presentedViewController as? UIAlertController, "候補の選択肢が出る")
        XCTAssertEqual(sheet.title, "どの授業の質問ですか?")
        XCTAssertTrue(sheet.message?.contains("旧約聖書と人間") ?? false)
        XCTAssertEqual(sheet.actions.first?.title, "おすすめ: 旧約聖書と人間", "予想した授業が、先頭")
        XCTAssertTrue(opened.isEmpty, "選ぶまでは、チャットを開かない")
        XCTAssertEqual(home.textView.text, "ダビデ王ってどんな人?", "選ぶまで、入力は消さない")
        typealias AlertHandler = @convention(block) (UIAlertAction) -> Void
        let raw = try XCTUnwrap(sheet.actions[0].value(forKey: "handler"), "選択肢の動作")
        unsafeBitCast(raw as AnyObject, to: AlertHandler.self)(sheet.actions[0])
        XCTAssertEqual(opened, ["bible"])
    }

    func testNoCoursesInTheTimetableExplainsInsteadOfGuessing() async throws {
        let home = makeHome(now: date(20, 20, 0), entries: [])
        home.textView.text = "質問"
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: home.textView)
        home.sendTapped()
        for _ in 0..<50 where home.presentedViewController == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual((home.presentedViewController as? UIAlertController)?.title, "授業が登録されていません")
    }

    func testCancelledClassIsNotPickedAutomatically() {
        UserDefaults.standard.set([QuickAskRouting.dayID(of: date(20, 11, 30))], forKey: "note.cancelled.reading")
        defer { UserDefaults.standard.removeObject(forKey: "note.cancelled.reading") }
        let home = makeHome(now: date(20, 11, 30))
        XCTAssertNil(home.selected, "休講の授業には、自動で振らない")
    }

    // MARK: 最近のチャット
    func testRecentChatsAreOnePerCourseAndSessionNewestFirstAndOnlyForThisTerm() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("home-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try LocalSourceStore(uid: "home-uid", baseURL: base)
        func context(_ uuid: String, day: Int, year: Int = 2026, semester: String = "fall") -> AIInputContext {
            AIInputContext(ownerUID: "home-uid", localCourseId: uuid, classDocId: nil, year: year, semester: semester, dayID: day)
        }
        func send(_ text: String, _ context: AIInputContext) throws {
            try store.submit(context: context, snapshots: [AIChatSnapshot(id: UUID().uuidString, context: context, kind: "question", text: text, sourceIDs: [], createdAt: Date())])
            Thread.sleep(forTimeInterval: 0.01)
        }
        try send("読解の質問1", context(uuidReading, day: 20000))
        try send("聖書の質問", context(uuidBible, day: 20000))
        try send("読解の質問2", context(uuidReading, day: 20000))   // 同じ授業・同じ回は、新しい方だけ
        try send("読解・別の回", context(uuidReading, day: 20007))
        try send("去年の質問", context(uuidReading, day: 19000, year: 2025))   // 別の学期は、出さない
        let recents = AIHomeViewController.recentChats(store: store, entries: makeEntries(), term: TermKey(year: 2026, semester: .fall))
        XCTAssertEqual(recents.count, 3, "授業×回ごとに1行。別の学期は出ない")
        XCTAssertEqual(recents.first?.subtitle, "読解・別の回", "新しい順")
        XCTAssertEqual(recents.first?.entry.course.id, "reading"); XCTAssertEqual(recents.first?.dayID, 20007)
        XCTAssertEqual(Set(recents.map(\.subtitle)), ["読解・別の回", "読解の質問2", "聖書の質問"])
        XCTAssertTrue(recents.allSatisfy { $0.title.contains(" · ") })
    }

    // MARK: 予想への入力
    func testPredictorPayloadMergesSameCourseAndLimitsSizes() {
        let reading = course("reading", "Reading II", uuid: uuidReading)
        let entries = [QuickAskCourse(course: reading, location: SlotLocation(day: 1, period: 2)), QuickAskCourse(course: reading, location: SlotLocation(day: 3, period: 1))]
        let payload = QuickAskPredictor.payload(question: String(repeating: "あ", count: 2000), photo: nil, entries: entries,
                                                recentQuestions: { _ in ["質問A", String(repeating: "い", count: 100), "質問C", "質問D"] })
        let courses = payload["courses"] as? [[String: Any]]
        XCTAssertEqual(courses?.count, 1, "同じ授業は、1つにまとめる")
        XCTAssertEqual((payload["question"] as? String)?.count, 600)
        let hint = courses?.first?["hint"] as? String ?? ""
        XCTAssertLessThanOrEqual(hint.count, 500)
        XCTAssertTrue(hint.contains("最近の質問") && !hint.contains("質問A"), "最近の質問は、新しい3つだけ")
        XCTAssertNil(payload["image"])
    }

    // MARK: タブの置き換え
    func testSyllabusTabIsReplacedByTheAITabAndNothingElseMoves() throws {
        func nav(_ title: String) -> UINavigationController {
            let nav = UINavigationController(rootViewController: UIViewController()); nav.tabBarItem = UITabBarItem(title: title, image: nil, tag: 0); return nav
        }
        let tab = UITabBarController()
        tab.viewControllers = ["時間割", "シラバス", "課題", "友だち", "インターン"].map(nav)
        SceneDelegate.replaceSyllabusTabWithAI(in: tab, isSyllabusTab: { $0.tabBarItem.title == "シラバス" })
        let after = tab.viewControllers?.map { $0.tabBarItem.title ?? "" } ?? []
        XCTAssertEqual(after, ["時間割", "AI", "課題", "友だち", "インターン"], "2番目だけが、AIになる。タブは5つのまま")
        XCTAssertTrue(((tab.viewControllers?[1] as? UINavigationController)?.viewControllers.first) is AIHomeViewController)
        XCTAssertEqual(tab.viewControllers?[1].tabBarItem.image, UIImage(systemName: "sparkles"))
        SceneDelegate.replaceSyllabusTabWithAI(in: tab, isSyllabusTab: { $0.tabBarItem.title == "シラバス" })   // 2回呼んでも、壊れない
        XCTAssertEqual(tab.viewControllers?.map { $0.tabBarItem.title ?? "" }, after)
        let short = UITabBarController(); short.viewControllers = [nav("時間割")]
        SceneDelegate.replaceSyllabusTabWithAI(in: short, isSyllabusTab: { _ in true })   // タブが足りないときは、触らない
        XCTAssertEqual(short.viewControllers?.count, 1)
    }

    // MARK: 設定に仕舞った3つ
    func testSettingsToolRowsAreSyllabusCreditsAndCalendar() {
        final class Target: NSObject { var taps: [String] = []; @objc func a() { taps.append("a") }; @objc func b() { taps.append("b") }; @objc func c() { taps.append("c") } }
        let target = Target()
        let rows = [TimetableSettingsViewController.toolRow(symbol: "magnifyingglass", title: "シラバスを探す", subtitle: "s", target: target, action: #selector(Target.a)),
                    TimetableSettingsViewController.toolRow(symbol: "graduationcap", title: "単位", subtitle: "s", target: target, action: #selector(Target.b)),
                    TimetableSettingsViewController.toolRow(symbol: "calendar", title: "学事暦", subtitle: "s", target: target, action: #selector(Target.c))]
        XCTAssertEqual(rows.map(\.accessibilityIdentifier), ["timetable-settings-magnifyingglass", "timetable-settings-graduationcap", "timetable-settings-calendar"])
        rows.compactMap { $0 as? UIButton }.forEach { $0.sendActions(for: .touchUpInside) }
        XCTAssertEqual(target.taps, ["a", "b", "c"], "それぞれ、別の動作につながっている")
        XCTAssertEqual((rows[0] as? UIButton)?.configuration?.title, "シラバスを探す")
    }
}
