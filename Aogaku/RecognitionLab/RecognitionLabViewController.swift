#if DEBUG
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class RecognitionLabViewController: UIViewController, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    private let stack = UIStackView(), preview = UIImageView(), status = UILabel(), output = UITextView()
    private let modes = UISegmentedControl(items: ["OCRのみ", "AIのみ", "OCR + AI"])
    private let onDevice = UISwitch(), deviceRow = UIStackView()
    private let deviceNotice = UILabel()
    private let runButton = UIButton(type: .system)
    private let service = LabDevRecognitionProvider(), apple = AppleLabSpeechRecognizer()
    private var imageData: Data?, audioURL: URL?, audioMime = "audio/mp4"
    private var comparison: LabComparison?
    private var work: Task<Void, Never>?
    private var importedURL: URL?
    private var busy = false
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Recognition Lab"; view.backgroundColor = .systemBackground
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        stack.axis = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)])
        let intro = UILabel(); intro.numberOfLines = 0; intro.font = .systemFont(ofSize: 14)
        intro.text = "開発専用・比較だけを実行します。AI資料への保存、Tasks、productionへの送信は行いません。\n「AIを使わない」＝外部LLM / Groqを使わない（VisionはGoogle API）。\n画像3MB以下、音声3MB・60秒以下。"
        stack.addArrangedSubview(intro)
        let buttons = UIStackView(); buttons.spacing = 12; buttons.distribution = .fillEqually
        buttons.addArrangedSubview(button("画像を選択", #selector(selectImage))); buttons.addArrangedSubview(button("音声ファイル", #selector(selectAudio))); stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(button("架空の画像fixtureを選択", #selector(selectFixture)))
        stack.addArrangedSubview(button("Dev接続 / モデル利用可否", #selector(connectDev)))
        stack.addArrangedSubview(button("端末UIDをコピー（初回登録用）", #selector(copyDeviceUID)))
        preview.contentMode = .scaleAspectFit; preview.backgroundColor = .secondarySystemBackground; preview.heightAnchor.constraint(equalToConstant: 230).isActive = true; preview.isHidden = true; stack.addArrangedSubview(preview)
        modes.selectedSegmentIndex = 0; modes.accessibilityIdentifier = "recognition-lab-mode"; stack.addArrangedSubview(modes)
        onDevice.isOn = true; let deviceLabel = UILabel(); deviceLabel.text = "Appleを端末内だけで認識"; deviceLabel.font = .systemFont(ofSize: 14); deviceRow.spacing = 10; deviceRow.addArrangedSubview(deviceLabel); deviceRow.addArrangedSubview(onDevice); deviceRow.isHidden = true; stack.addArrangedSubview(deviceRow)
        deviceNotice.numberOfLines = 0; deviceNotice.font = .systemFont(ofSize: 12); deviceNotice.text = "スイッチOFFではAppleのネットワーク認識を許可します。端末内認識未対応・権限拒否はエラーとして表示します。"; deviceNotice.isHidden = true; stack.addArrangedSubview(deviceNotice)
        runButton.setTitle("比較を実行（資料として保存しない）", for: .normal); runButton.addTarget(self, action: #selector(run), for: .touchUpInside); runButton.accessibilityIdentifier = "recognition-lab-run"; stack.addArrangedSubview(runButton)
        status.numberOfLines = 0; status.font = .systemFont(ofSize: 14); status.text = AppBackend.isOffline ? "Local：Apple Speechとfixtureを利用可能。Vision / GroqはDev Schemeで実行してください。" : "Dev：ログイン入力不要。端末を自動認証します（初回だけUID登録が必要）。"; stack.addArrangedSubview(status)
        output.isEditable = false; output.isScrollEnabled = false; output.font = .monospacedSystemFont(ofSize: 14, weight: .regular); output.accessibilityIdentifier = "recognition-lab-results"; output.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true; stack.addArrangedSubview(output)
        stack.addArrangedSubview(button("比較結果JSONを端末内へ保存", #selector(saveLocal)))
        if !AppBackend.isOffline { connectDev() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true { work?.cancel() }
    }
    deinit { if let importedURL { try? FileManager.default.removeItem(at: importedURL) } }
    private func button(_ title: String, _ action: Selector) -> UIButton { let b = UIButton(type: .system); b.setTitle(title, for: .normal); b.addTarget(self, action: action, for: .touchUpInside); return b }
    private func setBusy(_ value: Bool) { busy = value; runButton.isEnabled = !value; modes.isEnabled = !value; onDevice.isEnabled = !value }
    @objc private func selectImage() {
        guard !busy else { return }
        var config = PHPickerConfiguration(); config.filter = .images; config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config); picker.delegate = self; present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in Task { @MainActor in if let image = object as? UIImage { self?.useImage(image) } } }
    }
    @objc private func selectFixture() {
        guard !busy else { return }
        let menu = UIAlertController(title: "架空fixture", message: "手書きfixtureはスタイル付き注記です。実際の筆跡評価には選択画像を使ってください。", preferredStyle: .actionSheet)
        for kind in RecognitionLabFixtures.Kind.allCases { menu.addAction(UIAlertAction(title: kind.rawValue, style: .default) { [weak self] _ in self?.useImage(RecognitionLabFixtures.image(kind)) }) }
        menu.addAction(UIAlertAction(title: "キャンセル", style: .cancel)); menu.popoverPresentationController?.sourceView = view; menu.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: 160, width: 1, height: 1); present(menu, animated: true)
    }
    private func useImage(_ image: UIImage) {
        guard !busy else { return }
        let scale = min(1, 1600 / max(image.size.width, image.size.height)), size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = resized.jpegData(compressionQuality: 0.88), data.count <= 3 * 1024 * 1024 else { status.text = "画像が3MBを超えています"; return }
        imageData = data; audioURL = nil; comparison = nil; output.text = ""; preview.image = resized; preview.isHidden = false; deviceRow.isHidden = true; deviceNotice.isHidden = true
        setModes(["OCRのみ", "AIのみ", "OCR + AI"]); status.text = "元画像の向きを正規化・最大1600pxに縮小しました。比較を実行してください。"
    }
    private func setModes(_ values: [String]) { modes.removeAllSegments(); for (i, title) in values.enumerated() { modes.insertSegment(withTitle: title, at: i, animated: false) }; modes.selectedSegmentIndex = 0 }
    @objc private func selectAudio() {
        guard !busy else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true); picker.delegate = self; present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased(); guard ["m4a", "wav", "mp3"].contains(ext) else { throw AIInputError.message("m4a / wav / mp3を選択してください") }
            let length = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max; guard length <= 3 * 1024 * 1024 else { throw AIInputError.message("音声は3MB以下です") }
            if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("recognition-lab-\(UUID().uuidString).\(ext)"); try FileManager.default.copyItem(at: url, to: copy); importedURL = copy; audioURL = copy; audioMime = ext == "wav" ? "audio/wav" : ext == "mp3" ? "audio/mpeg" : "audio/mp4"
            imageData = nil; comparison = nil; preview.isHidden = true; deviceRow.isHidden = false; deviceNotice.isHidden = false; output.text = ""; setModes(["Apple", "Groq", "Apple + Groq"]); status.text = "音声ファイルを読み込みました（60秒以下）。両方式に同じファイルを渡します。"
        } catch { status.text = error.localizedDescription }
    }
    @objc private func connectDev() {
        guard !busy else { return }
        setBusy(true)
        work = Task {
            do { status.text = try await service.capabilities() }
            catch { status.text = error.localizedDescription }
            setBusy(false)
        }
    }
    @objc private func copyDeviceUID() {
        guard !busy else { return }
        setBusy(true)
        work = Task {
            do {
                let uid = try await service.ensureSession()
                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: uid]], options: [.expirationDate: Date().addingTimeInterval(300)])
                status.text = "端末UIDをコピーしました（5分間）。Macで python3 scripts/recognition_lab_dev.py register-device を実行し、貼り付けてください。登録後「Dev接続」を押してください。"
            } catch { status.text = error.localizedDescription }
            setBusy(false)
        }
    }
    @objc private func run() {
        guard RecognitionLabAccess.available, !busy else { return }
        let mode = modes.selectedSegmentIndex, image = imageData, audio = audioURL, deviceOnly = onDevice.isOn
        guard image != nil || audio != nil else { status.text = "画像か音声を選択してください"; return }
        comparison = nil; output.text = ""; status.text = "比較中…"; setBusy(true)
        work = Task {
            do {
                if let image { comparison = try await service.recognize(image: image, mime: "image/jpeg", mode: LabImageMode.allCases[mode]) }
                else if let audio {
                    let duration = try await AVURLAsset(url: audio).load(.duration).seconds
                    guard duration.isFinite, duration > 0, duration <= 60 else { throw AIInputError.message("Labは60秒以下の録音で比較します") }
                    var results: [LabRecognitionResult] = []
                    if mode != 1 { results.append(await apple.recognize(file: audio, onDeviceOnly: deviceOnly)) }
                    try Task.checkCancellation()
                    if mode != 0 {
                        let started = Date()
                        do { results.append(try await service.audio(Data(contentsOf: audio), mime: audioMime)) }
                        catch { results.append(.failure(AppBackend.isOffline ? "DEV_CONNECTION_REQUIRED" : "LAB_GROQ_REQUEST_FAILED", method: "groq_asr", provider: "groq", model: "whisper-large-v3-turbo", started: started)) }
                    }
                    comparison = .audio(results, method: LabAudioMode.allCases[mode].rawValue)
                }
                if let comparison { render(comparison) }
            } catch { status.text = error.localizedDescription }
            setBusy(false)
        }
    }
    private func render(_ value: LabComparison) {
        status.text = "比較完了・AI資料として未保存"
        var lines = ["Recognition mode: \(value.method)"]
        for result in value.results {
            let heading = result.method == "vision_ocr" ? "OCR raw" : result.provider == "apple" ? "Apple Transcript" : result.method == "groq_asr" ? "Groq Transcript" : "AI interpretation"
            lines += ["\n--- \(heading) ---", result.method == "vision_ocr" || result.method == "groq_asr" || result.provider == "apple" ? result.rawText : result.normalizedText,
                      "Method: \(result.method)", "Provider: \(result.provider)", "Model / recognizer: \(result.model)", String(format: "Processing: %.2f sec", result.processingMs / 1000), "文字数: \(result.characterCount)", "Error: \(result.error ?? "なし")", "Warnings: \(result.warnings.joined(separator: ", "))"]
            if let structure = result.structuredResult { lines += ["--- Raw structured result ---", structure] }
        }
        if let ocr = value.ocrTextProvidedToAI { lines += ["\n--- AIに渡したOCR text ---", ocr] }
        if imageData != nil { lines += ["\n--- Final evidence text（採用候補・未保存）---", value.finalEvidenceText] }
        lines += ["Warnings: \(value.warnings.joined(separator: ", "))"]
        lines += LabCostPresentation.lines(for: value)
        output.text = lines.joined(separator: "\n")
    }
    @objc private func saveLocal() {
        guard let comparison, !busy else { status.text = "比較後に保存できます"; return }
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RecognitionLab")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(comparison).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"), options: [.atomic, .completeFileProtection])
            status.text = "Files → このiPhone内 → 青山ハック Dev → RecognitionLabへ保存。クラウド資料には送信していません。"
        } catch { status.text = error.localizedDescription }
    }
}
#endif
