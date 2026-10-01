//
//  ActionViewController.swift
//  AogakuAction
//
//  Safari の Share sheet から呼び出されるAction Extension。
//  Action.js が completionFunction({payloadJSON: ...}) でデータを渡し、
//  Swift 側が extensionContext?.open() でアプリを起動する。
//  （location.href 方式と異なりシステムダイアログが出ない）
//

import UIKit
import PDFKit
import UniformTypeIdentifiers

final class ActionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // MARK: - UI

    private let indicator = UIActivityIndicatorView(style: .large)
    private let statusLabel  = UILabel()   // メインステータス（大きめ）
    private let detailLabel  = UILabel()   // サブ説明（小さめ・グレー）
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let sessionStepper = UIStepper()
    private let sessionLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private var stackCenterYConstraint: NSLayoutConstraint?

    private var sharedPDF: SharedLectureMaterial?
    private var timetableCourses: [ShareCourseOption] = []
    private var selectedCourseIndex: Int?
    private var selectedSessionNumber = 1

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        processExtensionData()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground

        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()

        statusLabel.text = "📊 時間割と単位状況を取得中..."
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.text = "科目ごとにシラバスURLを確認しています\n成績データも同時に取得します\n10〜30秒ほどかかる場合があります"
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [indicator, statusLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let centerY = stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        stackCenterYConstraint = centerY
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerY,
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])
    }

    // MARK: - Data Processing

    private func processExtensionData() {
        if processPDFIfAvailable() {
            return
        }

        guard
            let item     = extensionContext?.inputItems.first as? NSExtensionItem,
            let provider = item.attachments?.first,
            provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
        else {
            finishWithError("データを受け取れませんでした")
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error = error {
                    self.finishWithError(error.localizedDescription)
                    return
                }

                guard let resolvedPayload = self.resolvePayload(from: result) else {
                    // nil になるケース：JS が location.href='aogaku://...' でデータを送った直後に
                    // completionFunction({}) を呼ぶと、iOS が URL スキームに反応して
                    // ページ遷移が始まり、completionFunction のペイロードが破損/nil になる。
                    // これは正常な sendToApp フローの副作用なので、エラーではなく
                    // 「起動中」として静かに閉じる。
                    let summary = self.describeExtensionResult(result)
                    NSLog("[AogakuAction] payload nil (likely location.href transfer): %@", summary)
                    self.indicator.stopAnimating()
                    self.statusLabel.text = "🔄 青山ハックを起動中..."
                    self.detailLabel.text = "少々お待ちください"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    }
                    return
                }

                // JS が sendToApp()（location.href 方式）でデータ送信済みを明示的に通知してきた場合
                if resolvedPayload["__urlSchemeSent"] as? Bool == true {
                    self.indicator.stopAnimating()
                    self.statusLabel.text = "🔄 青山ハックを起動中..."
                    self.detailLabel.text = "少々お待ちください"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    }
                    return
                }

                if let jsError = resolvedPayload["error"] as? String {
                    self.finishWithError("JS エラー: \(jsError)")
                    return
                }

                // 成績データの場合は別経路で処理
                if resolvedPayload["type"] as? String == "grades" {
                    self.openMainAppWithGrades(resolvedPayload)
                    return
                }

                let subjectCount = (resolvedPayload["subjects"] as? [[String: Any]])?.count ?? -1
                let days = resolvedPayload["days"] as? [String] ?? []
                NSLog("[AogakuAction] JS result: subjects=%d days=%@", subjectCount, days)

                if subjectCount == 0 {
                    self.finishWithError("授業が見つかりませんでした（subjects=0）\nポータルの時間割ページで試してください")
                    return
                }

                self.openMainApp(with: resolvedPayload)
            }
        }
    }

    // MARK: - PDF / File Sharing

    private func processPDFIfAvailable() -> Bool {
        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let providers = item.attachments
        else {
            return false
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }) {
            statusLabel.text = "PDFを読み込んでいます..."
            detailLabel.text = "保存先の授業を選べるように準備しています"
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { [weak self] url, error in
                let material = url.flatMap { self?.sharedMaterial(from: $0) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.finishWithError(error.localizedDescription)
                        return
                    }
                    guard url != nil else {
                        self.finishWithError("PDFを受け取れませんでした")
                        return
                    }
                    guard let material else {
                        self.finishWithError("PDFを読み込めませんでした")
                        return
                    }
                    self.prepareSharedPDF(material)
                }
            }
            return true
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            statusLabel.text = "ファイルを読み込んでいます..."
            detailLabel.text = "保存先の授業を選べるように準備しています"
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.finishWithError(error.localizedDescription)
                        return
                    }
                    guard let url = item as? URL, url.pathExtension.lowercased() == "pdf" else {
                        self.finishWithError("PDFファイルを選んでください")
                        return
                    }
                    self.prepareSharedPDF(self.sharedMaterial(from: url))
                }
            }
            return true
        }

        return false
    }

    private func sharedMaterial(from url: URL) -> SharedLectureMaterial {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        return SharedLectureMaterial(fileName: url.lastPathComponent, text: extractPDFText(from: url))
    }

    private func prepareSharedPDF(_ material: SharedLectureMaterial) {
        let text = material.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            finishWithError("PDFから文字を読み取れませんでした")
            return
        }

        sharedPDF = SharedLectureMaterial(fileName: material.fileName, text: text)
        timetableCourses = loadShareCourseOptions()
        guard !timetableCourses.isEmpty else {
            finishWithError("時間割の授業が見つかりませんでした\n一度アプリを開いて時間割を表示してください")
            return
        }
        selectedCourseIndex = 0
        selectedSessionNumber = defaultSessionNumber()
        showPDFSaveUI()
    }

    private func extractPDFText(from url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }

    private func showPDFSaveUI() {
        indicator.stopAnimating()
        indicator.isHidden = true
        statusLabel.text = "授業ノートに保存"
        detailLabel.text = sharedPDF?.fileName ?? "PDF"
        stackCenterYConstraint?.isActive = false

        sessionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        sessionLabel.textColor = .label
        sessionLabel.textAlignment = .center
        sessionLabel.translatesAutoresizingMaskIntoConstraints = false

        sessionStepper.minimumValue = 1
        sessionStepper.maximumValue = 30
        sessionStepper.value = Double(selectedSessionNumber)
        sessionStepper.addTarget(self, action: #selector(sessionStepperChanged), for: .valueChanged)
        sessionStepper.translatesAutoresizingMaskIntoConstraints = false

        saveButton.configuration = .filled()
        saveButton.configuration?.title = "この授業に保存"
        saveButton.configuration?.cornerStyle = .medium
        saveButton.addTarget(self, action: #selector(saveSharedPDFTapped), for: .touchUpInside)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        view.addSubview(sessionLabel)
        view.addSubview(sessionStepper)
        view.addSubview(saveButton)

        updateSessionLabel()
        updateSaveButton()

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: sessionLabel.topAnchor, constant: -12),

            sessionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            sessionLabel.centerYAnchor.constraint(equalTo: sessionStepper.centerYAnchor),

            sessionStepper.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            sessionStepper.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -14),

            saveButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            saveButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            saveButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            saveButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    @objc private func sessionStepperChanged() {
        selectedSessionNumber = Int(sessionStepper.value)
        updateSessionLabel()
    }

    private func updateSessionLabel() {
        sessionLabel.text = "第\(selectedSessionNumber)回として保存"
    }

    private func updateSaveButton() {
        saveButton.isEnabled = selectedCourseIndex != nil
    }

    private func defaultSessionNumber() -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.component(.month, from: Date())
        if (4...8).contains(month) {
            return max(1, min(15, calendar.component(.weekOfYear, from: Date()) - 14))
        }
        return max(1, min(15, calendar.component(.weekOfYear, from: Date()) - 37))
    }

    @objc private func saveSharedPDFTapped() {
        guard
            let material = sharedPDF,
            let selectedCourseIndex,
            timetableCourses.indices.contains(selectedCourseIndex)
        else {
            return
        }

        let selected = timetableCourses[selectedCourseIndex]
        let payload = PendingLectureMaterialPayload(
            fileName: material.fileName,
            text: material.text,
            courseID: selected.course.id,
            courseFirestoreDocID: selected.course.firestoreDocID,
            courseTitle: selected.course.title,
            courseCampus: selected.course.campus,
            dayPeriod: selected.dayPeriod,
            weekday: selected.weekday,
            termYear: selected.termYear,
            termSemester: selected.termSemester,
            termDisplayTitle: selected.termDisplayTitle,
            sessionNumber: selectedSessionNumber
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            finishWithError("保存データの作成に失敗しました")
            return
        }

        let defaults = UserDefaults(suiteName: "group.jp.forta.Aogaku")
        defaults?.set(data, forKey: "pendingLectureMaterial")
        defaults?.synchronize()

        statusLabel.text = "保存中..."
        detailLabel.text = "\(selected.course.title) 第\(selectedSessionNumber)回"
        tableView.isHidden = true
        saveButton.isHidden = true
        sessionStepper.isHidden = true
        sessionLabel.isHidden = true
        indicator.isHidden = false
        indicator.startAnimating()

        let url = URL(string: "aogaku://lecture-material")!
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indicator.stopAnimating()
                if success {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.statusLabel.text = "保存準備ができました"
                    self.detailLabel.text = "青山ハックを開くと授業ノートに保存されます"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    }
                }
            }
        }
    }

    private func loadShareCourseOptions() -> [ShareCourseOption] {
        guard let defaults = UserDefaults(suiteName: "group.jp.forta.Aogaku") else { return [] }
        let selectedTermKey = defaults.string(forKey: "tt.term") ?? defaultTermStorageKey()
        let term = parseTerm(from: selectedTermKey)
        let dayCount = max(defaults.integer(forKey: "tt.days"), 5)
        let periodCount = max(defaults.integer(forKey: "tt.periods"), 5)
        let key = "tt.assigned.\(selectedTermKey)"
        guard let data = defaults.data(forKey: key) else { return [] }

        let coursesWithSlots: [(Int, ActionCourse)]
        if let decoded = try? JSONDecoder().decode([ActionCourse?].self, from: data) {
            coursesWithSlots = decoded.enumerated().compactMap { index, course in
                course.map { (index, $0) }
            }
        } else if let decoded = try? JSONDecoder().decode([ActionCourse].self, from: data) {
            coursesWithSlots = decoded.enumerated().map { ($0.offset, $0.element) }
        } else {
            return []
        }

        return coursesWithSlots.compactMap { index, course in
            let day = index % dayCount
            let period = index / dayCount + 1
            guard period <= periodCount else { return nil }
            let dayName = ["月", "火", "水", "木", "金", "土"].indices.contains(day)
                ? ["月", "火", "水", "木", "金", "土"][day]
                : "?"
            return ShareCourseOption(
                course: course,
                dayPeriod: "\(dayName)\(period)",
                weekday: day,
                termYear: term.year,
                termSemester: term.semester,
                termDisplayTitle: "\(term.year)年\(term.semester)"
            )
        }
        .filter { !$0.course.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .sorted { lhs, rhs in
            if lhs.weekday != rhs.weekday { return lhs.weekday < rhs.weekday }
            return lhs.dayPeriod < rhs.dayPeriod
        }
    }

    private func parseTerm(from storageKey: String) -> (year: Int, semester: String) {
        let fallback = defaultTermParts()
        let tail = storageKey.replacingOccurrences(of: "assignedCourses.", with: "")
        let parts = tail.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, let year = Int(parts[0]) else { return fallback }
        return (year, parts[1])
    }

    private func defaultTermStorageKey() -> String {
        let parts = defaultTermParts()
        return "assignedCourses.\(parts.year)_\(parts.semester)"
    }

    private func defaultTermParts() -> (year: Int, semester: String) {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        if (4...8).contains(month) { return (year, "前期") }
        if (9...12).contains(month) { return (year, "後期") }
        return (year - 1, "後期")
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        timetableCourses.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let option = timetableCourses[indexPath.row]
        cell.textLabel?.text = option.course.title
        cell.detailTextLabel?.text = "\(option.dayPeriod)・\(option.course.teacher)"
        cell.accessoryType = indexPath.row == selectedCourseIndex ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedCourseIndex = indexPath.row
        tableView.reloadData()
        updateSaveButton()
    }

    private func resolvePayload(from result: Any?) -> [String: Any]? {
        if let payloadJSON = result as? String {
            return decodePayloadJSON(payloadJSON)
        }
        if let data = result as? Data {
            return resolvePayloadData(data)
        }
        if let data = result as? NSData {
            return resolvePayloadData(data as Data)
        }
        if let array = result as? [Any] {
            for item in array {
                if let resolved = resolvePayload(from: item) {
                    return resolved
                }
            }
            return nil
        }
        if let array = result as? NSArray {
            for item in array {
                if let resolved = resolvePayload(from: item) {
                    return resolved
                }
            }
            return nil
        }

        guard let dict = stringKeyDictionary(from: result) else { return nil }

        // NSKeyedArchive 構造（$archiver/$objects/$top/$version）が直接来た場合はデコードする
        if dict["$archiver"] != nil {
            return resolveKeyedArchivePayload(dict)
        }

        let nestedAny = dict[NSExtensionJavaScriptPreprocessingResultsKey]
            ?? dict["NSExtensionJavaScriptPreprocessingResultsKey"]
            ?? dict["results"]
            ?? dict["payload"]
            ?? dict["NSExtensionItemAttachmentsKey"]

        if let nestedJSON = nestedAny as? String {
            return decodePayloadJSON(nestedJSON)
        }
        if let nestedData = nestedAny as? Data {
            return resolvePayloadData(nestedData)
        }
        if let nestedData = nestedAny as? NSData {
            return resolvePayloadData(nestedData as Data)
        }
        if let nestedDict = stringKeyDictionary(from: nestedAny) {
            return resolvePayloadDictionary(nestedDict)
        }
        if let nestedArray = nestedAny as? [Any] {
            return resolvePayload(from: nestedArray)
        }
        if let nestedArray = nestedAny as? NSArray {
            return resolvePayload(from: nestedArray)
        }

        return resolvePayloadDictionary(dict)
    }

    private func resolvePayloadDictionary(_ dict: [String: Any]) -> [String: Any]? {
        if let payloadJSON = dict["payloadJSON"] as? String {
            return decodePayloadJSON(payloadJSON)
        }
        if dict["subjects"] is [[String: Any]] || dict["error"] is String {
            return dict
        }
        // 空 dict = JS が sendToApp() でデータを送信済み → 拡張を閉じるだけ
        if dict.isEmpty {
            return ["__urlSchemeSent": true]
        }
        return nil
    }

    private func decodePayloadJSON(_ payloadJSON: String) -> [String: Any]? {
        guard let payloadData = payloadJSON.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return decoded
    }

    private func resolvePayloadData(_ data: Data) -> [String: Any]? {
        if let unarchived = unarchiveExtensionPayload(data),
           let resolved = resolvePayload(from: unarchived) {
            return resolved
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) {
            if let resolved = resolveKeyedArchivePayload(plist) {
                return resolved
            }
            if let resolved = resolvePayload(from: plist) {
                return resolved
            }
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return resolvePayloadDictionary(json)
        }

        if let text = String(data: data, encoding: .utf8) {
            return decodePayloadJSON(text)
        }

        return nil
    }

    private func unarchiveExtensionPayload(_ data: Data) -> Any? {
        if let object = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) {
            return object
        }

        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            let object = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            unarchiver.finishDecoding()
            return object
        } catch {
            NSLog("[AogakuAction] keyed unarchive failed: %@", error.localizedDescription)
        }

        return try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
    }

    private func resolveKeyedArchivePayload(_ plist: Any) -> [String: Any]? {
        guard
            let archive = stringKeyDictionary(from: plist),
            archive["$archiver"] != nil,
            let objects = archive["$objects"] as? [Any],
            let top = stringKeyDictionary(from: archive["$top"]),
            let rootIndex = keyedArchiveIndex(top["root"]),
            rootIndex >= 0,
            rootIndex < objects.count
        else {
            return nil
        }

        let decodedRoot = decodeArchivedObject(at: rootIndex, objects: objects)
        return resolvePayload(from: decodedRoot)
    }

    private func decodeArchivedObject(at index: Int, objects: [Any]) -> Any? {
        guard index >= 0, index < objects.count else { return nil }
        let object = objects[index]

        if let dict = stringKeyDictionary(from: object) {
            if let string = dict["NS.string"] as? String {
                return string
            }
            if let data = dict["NS.data"] as? Data {
                return data
            }
            if let data = dict["NS.data"] as? NSData {
                return data as Data
            }
            if let keys = dict["NS.keys"] as? [Any],
               let values = dict["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for (keyRef, valueRef) in zip(keys, values) {
                    guard
                        let keyIndex = keyedArchiveIndex(keyRef),
                        let valueIndex = keyedArchiveIndex(valueRef),
                        let key = decodeArchivedObject(at: keyIndex, objects: objects) as? String,
                        let value = decodeArchivedObject(at: valueIndex, objects: objects)
                    else {
                        continue
                    }
                    out[key] = value
                }
                return out
            }
            if let arrayRefs = dict["NS.objects"] as? [Any] {
                let decodedArray: [Any] = arrayRefs.compactMap { ref -> Any? in
                    guard let childIndex = keyedArchiveIndex(ref) else { return nil }
                    return decodeArchivedObject(at: childIndex, objects: objects)
                }
                return decodedArray
            }
            return dict
        }

        return object
    }

    private func keyedArchiveIndex(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }

        let mirror = Mirror(reflecting: value as Any)
        for child in mirror.children {
            if child.label == "value" || child.label == "_value" {
                if let int = child.value as? Int { return int }
                if let number = child.value as? NSNumber { return number.intValue }
            }
        }

        let description = String(describing: value as Any)
        if let match = description.range(of: #"(?<=value = )\d+"#, options: .regularExpression) {
            return Int(description[match])
        }
        if let match = description.range(of: #"\d+"#, options: .regularExpression) {
            return Int(description[match])
        }
        return nil
    }

    private func stringKeyDictionary(from value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let dict = value as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict {
                out[String(describing: key)] = value
            }
            return out
        }
        if let dict = value as? NSDictionary {
            var out: [String: Any] = [:]
            dict.forEach { key, value in
                out[String(describing: key)] = value
            }
            return out
        }
        return nil
    }

    private func describeExtensionResult(_ result: Any?) -> String {
        guard let result else { return "result=nil" }
        if let dict = stringKeyDictionary(from: result) {
            let keyList = Array(dict.keys).sorted().joined(separator: ",")
            let nested = dict[NSExtensionJavaScriptPreprocessingResultsKey]
                ?? dict["NSExtensionJavaScriptPreprocessingResultsKey"]
            let nestedType = nested.map { String(describing: type(of: $0)) } ?? "none"
            return "type=Dictionary keys=[\(keyList)] nested=\(nestedType)"
        }
        if let string = result as? String {
            return "type=String len=\(string.count) head=\(String(string.prefix(40)))"
        }
        if let data = result as? Data {
            let head = data.prefix(16).map { byte -> String in
                let hex = String(byte, radix: 16)
                return hex.count == 1 ? "0\(hex)" : hex
            }.joined()
            var format = PropertyListSerialization.PropertyListFormat.binary
            let plistSummary: String
            if let unarchived = unarchiveExtensionPayload(data) {
                plistSummary = " archive={\(describeExtensionResult(unarchived))}"
            } else if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) {
                plistSummary = " plist={\(describeExtensionResult(plist))}"
            } else {
                plistSummary = " plist=unreadable"
            }
            return "type=Data len=\(data.count) head=\(head)\(plistSummary)"
        }
        if let data = result as? NSData {
            return "type=NSData len=\(data.length)"
        }
        return "type=\(String(describing: type(of: result)))"
    }

    // MARK: - Save to App Group & Open App

    private func openMainAppWithGrades(_ json: [String: Any]) {
        statusLabel.text = "📊 成績データを転送中..."
        detailLabel.text = ""

        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            finishWithError("成績データの変換に失敗しました")
            return
        }

        let defaults = UserDefaults(suiteName: "group.jp.forta.Aogaku")
        defaults?.set(data, forKey: "pendingGradesImport")
        defaults?.synchronize()
        NSLog("[AogakuAction] saved %d bytes to pendingGradesImport", data.count)

        let url = URL(string: "aogaku://grades")!
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indicator.stopAnimating()
                if success {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.statusLabel.text = "✓ 成績データを保存しました"
                    self.detailLabel.text = "Aogakuアプリを開くと反映されます"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    }
                }
            }
        }
    }

    private func openMainApp(with json: [String: Any]) {
        statusLabel.text = "✓ 取得完了 — アプリを起動中..."
        detailLabel.text = ""

        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            finishWithError("データの変換に失敗しました")
            return
        }

        // App Group の共有 UserDefaults に先に保存しておく
        // → extensionContext?.open() が成功しても失敗しても、アプリ側で拾える
        let defaults = UserDefaults(suiteName: "group.jp.forta.Aogaku")
        if defaults == nil {
            NSLog("[AogakuAction] ⚠️ App Group UserDefaults is NIL – entitlement missing?")
        }
        defaults?.set(data, forKey: "pendingPortalImport")
        defaults?.synchronize()
        NSLog("[AogakuAction] saved %d bytes to pendingPortalImport (read-back: %@)",
              data.count,
              defaults?.data(forKey: "pendingPortalImport") != nil ? "OK" : "FAILED")

        // extensionContext?.open() はシステムダイアログなしにアプリを直接起動できる
        let url = URL(string: "aogaku://import")!

        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.indicator.stopAnimating()

                if success {
                    // アプリが開いた → sceneDidBecomeActive が pendingPortalImport を処理する
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    // 自動遷移できない場合 → App Group に保存済みなので
                    // ユーザーが次にアプリを開いたときに自動で取り込まれる
                    self.statusLabel.text = "✓ 取得完了"
                    self.statusLabel.textColor = .label
                    self.detailLabel.text = "Aogakuアプリを開くと時間割に反映されます"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    }
                }
            }
        }
    }

    // MARK: - Error

    private func finishWithError(_ message: String) {
        indicator.stopAnimating()
        statusLabel.text = "⚠️ \(message)"
        statusLabel.textColor = .systemRed
        detailLabel.text = ""

        let delay: TimeInterval = message.contains("\n") ? 6 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

private struct SharedLectureMaterial {
    let fileName: String
    let text: String
}

private struct ActionCourse: Codable {
    let id: String
    let title: String
    let room: String
    let teacher: String
    let credits: Int?
    let campus: String?
    let category: String?
    let syllabusURL: String?
    let term: String?
    let timeDay: String?
    let periods: [Int]?
    let firestoreDocID: String?
}

private struct ShareCourseOption {
    let course: ActionCourse
    let dayPeriod: String
    let weekday: Int
    let termYear: Int
    let termSemester: String
    let termDisplayTitle: String
}

private struct PendingLectureMaterialPayload: Codable {
    let fileName: String
    let text: String
    let courseID: String
    let courseFirestoreDocID: String?
    let courseTitle: String
    let courseCampus: String?
    let dayPeriod: String
    let weekday: Int
    let termYear: Int
    let termSemester: String
    let termDisplayTitle: String
    let sessionNumber: Int
}
