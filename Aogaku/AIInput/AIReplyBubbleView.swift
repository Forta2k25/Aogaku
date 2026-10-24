import UIKit
import FirebaseRemoteConfig

/// チャットに出すAIの返信。ChatGPTのように吹き出しを使わず、画面幅いっぱいの文章で出す。
/// 上に「思考プロセス」(送信→読み取り→返信の作成、の実際の流れと時間)、その下に文章を打っているように表示し、
/// 文章の下に、コピー・共有・「…」のアイコンと、「回答まで◯秒 ・ token ・ 料金」を小さく1行で出す。
@MainActor
final class AIReplyBubbleView: UIView {
    // 思考プロセス
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let processButton = UIButton(type: .system)
    private let stepsLabel = UILabel()
    private var steps: [AIReplyStep] = []
    private var liveText: String?
    private var processTotalMs: Double?
    private var stepsExpanded = true
    // 本文
    private let bodyView = UITextView()
    private let actionRow = UIStackView()
    private let copyButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let metaButton = UIButton(type: .system)
    private let detailLabel = UILabel()
    // 最初の文字が出るまでの「骨組み」(灰色の線が脈打つ)。待っている間も、何かが進んでいる感じを出す
    private let skeleton = UIStackView()
    // 追質問のボタン(返信の下に、横に並べる)
    /// 次の候補の置き場。横に並べて、入りきらないものは、次の行へ折り返す(横スクロールではないので、端が見切れない)。
    private let suggestionScroll = AISuggestionFlowView()
    private var plainText = ""
    private var detailVisible = false
    // 打っているような表示(Groqは全文を1秒ほどで返すため、表示側でペースを作る)
    private var typedSource: [Character] = []
    private var typedCount = 0
    private var typingTimer: Timer?
    private var streamFinished = false
    private var pendingFinish: (metrics: AIReplyMetrics?, usdJPY: Double?)?
    /// 失敗後の「もう一度」と、「…」メニューの「もう一度生成」の両方で呼ばれる。
    var onRetry: (() -> Void)?
    /// このやり取り(質問とこの返信)を消す。「…」のメニューに出す。
    var onDelete: (() -> Void)?
    /// 追質問のボタンが押されたとき、そのボタンの文言で呼ばれる(そのまま質問として送る)。
    var onSuggestion: ((String) -> Void)?
    /// 文章が伸びたときに呼ばれる(一番下にいるときに、画面を追従させるため)。
    var onContentGrow: (() -> Void)?

    /// 円換算の目安レート。Remote Config(ai_recognition_usd_jpy)があればそれを使い、無ければこの値。請求額ではなく目安。
    static let defaultUSDJPY: Double = 150
    static var displayUSDJPY: Double? {
        guard !AppBackend.isOffline else { return defaultUSDJPY }
        let rate = RemoteConfig.remoteConfig()["ai_recognition_usd_jpy"].numberValue.doubleValue
        return rate > 0 ? rate : defaultUSDJPY
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "ai-reply-bubble"

        spinner.hidesWhenStopped = true
        spinner.color = .secondaryLabel
        processButton.contentHorizontalAlignment = .leading
        processButton.addTarget(self, action: #selector(toggleSteps), for: .touchUpInside)
        processButton.accessibilityIdentifier = "ai-reply-process"
        let header = UIStackView(arrangedSubviews: [spinner, processButton, UIView()])
        header.axis = .horizontal
        header.spacing = 6
        header.alignment = .center
        stepsLabel.font = .systemFont(ofSize: 12)
        stepsLabel.textColor = .secondaryLabel
        stepsLabel.numberOfLines = 0
        stepsLabel.accessibilityIdentifier = "ai-reply-steps"

        bodyView.isEditable = false
        bodyView.isSelectable = true          // 長押しで一部だけ選んでコピーできる
        bodyView.isScrollEnabled = false
        bodyView.backgroundColor = .clear
        bodyView.textContainerInset = .zero
        bodyView.textContainer.lineFragmentPadding = 0
        bodyView.dataDetectorTypes = []
        bodyView.accessibilityIdentifier = "ai-reply-text"

        retryButton.setTitle("もう一度", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        retryButton.contentHorizontalAlignment = .leading
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        for (button, symbol, label) in [(copyButton, "doc.on.doc", "コピー"), (shareButton, "square.and.arrow.up", "共有"), (moreButton, "ellipsis", "その他")] {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)), for: .normal)
            button.tintColor = .secondaryLabel
            button.accessibilityLabel = label
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            actionRow.addArrangedSubview(button)
        }
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true
        actionRow.axis = .horizontal
        actionRow.spacing = 0
        actionRow.addArrangedSubview(UIView())   // 右側を空けて、アイコンを左に寄せる

        metaButton.titleLabel?.font = .systemFont(ofSize: 11)
        metaButton.titleLabel?.numberOfLines = 0
        metaButton.setTitleColor(.secondaryLabel, for: .normal)
        metaButton.contentHorizontalAlignment = .leading
        metaButton.accessibilityIdentifier = "ai-reply-meta"
        metaButton.addTarget(self, action: #selector(toggleDetail), for: .touchUpInside)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        skeleton.axis = .vertical
        skeleton.spacing = 10
        skeleton.alignment = .leading
        skeleton.isHidden = true
        for (index, fraction) in [1.0, 0.86, 0.58].enumerated() {
            let bar = UIView()
            bar.backgroundColor = .tertiarySystemFill
            bar.layer.cornerRadius = 6
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 12).isActive = true
            skeleton.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: skeleton.widthAnchor, multiplier: fraction).isActive = true
            bar.tag = index
        }
        suggestionScroll.isHidden = true
        suggestionScroll.translatesAutoresizingMaskIntoConstraints = false
        let column = UIStackView(arrangedSubviews: [header, stepsLabel, skeleton, bodyView, retryButton, actionRow, suggestionScroll, metaButton, detailLabel])
        column.axis = .vertical
        column.spacing = 6
        column.alignment = .fill
        column.setCustomSpacing(10, after: bodyView)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),   // 下の行が入力欄に接しないよう、ゆとりを取る
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
        resetBody()
        header.isHidden = true; stepsLabel.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { typingTimer?.invalidate() }

    private var headerStack: UIStackView { spinner.superview as! UIStackView }

    private func resetBody() {
        typingTimer?.invalidate(); typingTimer = nil
        typedSource = []; typedCount = 0; streamFinished = false; pendingFinish = nil
        plainText = ""
        bodyView.isHidden = true; bodyView.attributedText = nil
        retryButton.isHidden = true; actionRow.isHidden = true; metaButton.isHidden = true; detailLabel.isHidden = true
        suggestionScroll.isHidden = true
        suggestionScroll.setChips([])
        setSkeleton(false)
        detailVisible = false
    }

    // MARK: 追質問のボタン
    /// 返信の下に、ワンタップで送れる追質問を並べる。空なら隠す。
    func setSuggestions(_ titles: [String]) {
        suggestionScroll.setChips([])
        guard !titles.isEmpty else { suggestionScroll.isHidden = true; return }
        suggestionScroll.setChips(titles.map { title in AISuggestionChip(title: title) { [weak self] in self?.onSuggestion?(title) } })
        suggestionScroll.isHidden = actionRow.isHidden   // 文章を打ち終えて、下の行が出るまでは隠しておく
    }

    // MARK: 思考プロセス
    /// 処理中。完了した段階(✓ 送信 0.8秒 など)と、いま進めている段階(live)を出す。
    func showProcess(steps: [AIReplyStep], live: String) {
        resetBody()
        self.steps = steps; liveText = live; processTotalMs = nil
        headerStack.isHidden = false
        spinner.startAnimating()
        updateProcessUI()
        setSkeleton(true)
    }

    /// 灰色の線を、ゆっくり脈打たせて出す/隠す。
    private func setSkeleton(_ on: Bool) {
        guard skeleton.isHidden == on else { return }
        skeleton.isHidden = !on
        for (index, bar) in skeleton.arrangedSubviews.enumerated() {
            bar.layer.removeAnimation(forKey: "pulse")
            guard on else { continue }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0; pulse.toValue = 0.35
            pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.18
            pulse.fillMode = .backwards
            bar.layer.add(pulse, forKey: "pulse")
        }
    }

    private func finishProcess(totalMs: Double?, collapse: Bool) {
        liveText = nil; processTotalMs = totalMs
        spinner.stopAnimating()
        if collapse { stepsExpanded = false }
        headerStack.isHidden = steps.isEmpty && totalMs == nil
        updateProcessUI()
    }

    private func updateProcessUI() {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        config.imagePlacement = .trailing
        config.imagePadding = 4
        if let live = liveText {
            config.title = live
            config.baseForegroundColor = .secondaryLabel
        } else {
            config.title = processTotalMs.map { "思考プロセス ・ " + Self.seconds($0) } ?? "思考プロセス"
            config.baseForegroundColor = .secondaryLabel
        }
        config.image = UIImage(systemName: stepsExpanded ? "chevron.up" : "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0; a.font = .systemFont(ofSize: 13); return a }
        processButton.configuration = config
        var lines = steps.map { "✓ \($0.title)  \(Self.seconds($0.ms))" }
        if let live = liveText { lines.append("… " + live) }
        stepsLabel.text = lines.joined(separator: "\n")
        stepsLabel.isHidden = !stepsExpanded || steps.isEmpty   // 段階がまだ無いときは、上の1行と重複するので出さない
    }

    @objc private func toggleSteps() {
        stepsExpanded.toggle()
        updateProcessUI()
        UIView.animate(withDuration: 0.2) { self.superview?.layoutIfNeeded() }
    }

    // MARK: 本文
    func showError(_ text: String, retry: Bool) {
        resetBody()
        setSkeleton(false)
        spinner.stopAnimating(); liveText = nil
        updateProcessUI()
        headerStack.isHidden = steps.isEmpty
        plainText = text
        bodyView.isHidden = false
        bodyView.attributedText = Self.styled(text, color: .label)
        retryButton.isHidden = !retry
    }

    /// ストリーミングで届いた文字を足す。実際の表示は、打っているようなペースで進める。
    func appendStream(_ delta: String) {
        if bodyView.isHidden { setSkeleton(false); bodyView.isHidden = false; finishProcess(totalMs: nil, collapse: true); liveText = nil; spinner.stopAnimating(); updateProcessUI() }
        typedSource.append(contentsOf: Array(delta))
        startTyping()
    }

    /// 返信が出そろった。全文に差し替えて、打ち終わったら、アイコンと「秒・token・料金」を出す。
    func completeStream(fullText: String, metrics: AIReplyMetrics?, usdJPY: Double?) {
        setSkeleton(false)
        if bodyView.isHidden { bodyView.isHidden = false }
        typedSource = Array(fullText)
        streamFinished = true
        pendingFinish = (metrics, usdJPY)
        if let metrics { steps = metrics.steps ?? steps }
        finishProcess(totalMs: metrics?.totalMs, collapse: true)
        startTyping()
    }

    /// 保存済みの返信など、打たずにそのまま全文を出す。
    func showReply(_ text: String, metrics: AIReplyMetrics?, usdJPY: Double?) {
        resetBody()
        if let metrics { steps = metrics.steps ?? [] }
        finishProcess(totalMs: metrics?.totalMs, collapse: true)
        bodyView.isHidden = false
        render(text, final: true)
        showFooter(metrics: metrics, usdJPY: usdJPY)
    }

    private func startTyping() {
        guard typingTimer == nil else { return }
        typingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.typeTick() }
        }
    }

    private func typeTick() {
        let backlog = typedSource.count - typedCount
        if backlog > 0 {
            // 基本は1コマ3文字(約90文字/秒)。溜まったら速めて、表示が受信より0.4秒以上遅れないようにする
            // (AIの返信は届くのが速いので、打つ演出のせいで待たされないように)。
            typedCount += min(backlog, max(3, (backlog + 11) / 12))
            render(String(typedSource[0..<typedCount]), final: false)
            onContentGrow?()
        }
        if typedCount >= typedSource.count, streamFinished {
            typingTimer?.invalidate(); typingTimer = nil
            render(String(typedSource), final: true)
            if let done = pendingFinish { showFooter(metrics: done.metrics, usdJPY: done.usdJPY) }
            pendingFinish = nil
            onContentGrow?()
        } else if typedCount >= typedSource.count {
            typingTimer?.invalidate(); typingTimer = nil   // 続きが届くまで止める
        }
    }

    /// 打っている途中は、閉じていない数式($$ ... や $ ...)を隠す。書きかけの LaTeX がそのまま見えてしまうのを防ぐ(閉じたら数式として出る)。
    static func hidingOpenMath(_ text: String) -> String {
        var result = text
        if let open = openMathStart(result, token: "$$") { result = String(result[..<open]) }
        else {
            // $$ を除いたうえで、1個余っている $ があれば、そこから先を隠す。
            let scalars = Array(result)
            var singles: [Int] = [], i = 0
            while i < scalars.count {
                if scalars[i] == "$" { if i + 1 < scalars.count, scalars[i + 1] == "$" { i += 2; continue }; singles.append(i) }
                i += 1
            }
            if singles.count % 2 == 1, let last = singles.last { result = String(scalars[..<last]) }
        }
        // 「$」の直前の空白だけが残らないように整える。
        while result.last == " " || result.last == "\n" { result.removeLast() }
        return result
    }
    private static func openMathStart(_ text: String, token: String) -> String.Index? {
        var count = 0, last: String.Index?, search = text.startIndex..<text.endIndex
        while let r = text.range(of: token, range: search) { count += 1; last = r.lowerBound; search = r.upperBound..<text.endIndex }
        return count % 2 == 1 ? last : nil
    }

    private func render(_ text: String, final: Bool) {
        let attributed = Self.markdown(final ? text : Self.hidingOpenMath(text))
        plainText = attributed.string
        bodyView.attributedText = attributed
    }

    private func showFooter(metrics: AIReplyMetrics?, usdJPY: Double?) {
        actionRow.isHidden = false
        suggestionScroll.isHidden = suggestionScroll.chips.isEmpty
        var items: [UIMenuElement] = [
            UIAction(title: "もう一度生成", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.onRetry?() }
        ]
        if onDelete != nil {
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "このやり取りを削除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.onDelete?() }
            ]))
        }
        moreButton.menu = UIMenu(children: items)
        guard let metrics else { return }
        let line = Self.metaLine(metrics, usdJPY: usdJPY)
        metaButton.isHidden = line.isEmpty
        metaButton.setTitle(line, for: .normal)
        detailLabel.text = Self.detailText(metrics, usdJPY: usdJPY)
    }

    // MARK: 文章の見た目
    private static let bodySize: CGFloat = 15   // ChatGPTアプリの本文に近い大きさ
    private static let bodyFont = UIFont.systemFont(ofSize: bodySize)
    private static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.65    // ChatGPTのように、行間をゆったり取る
        style.paragraphSpacing = 6
        return style
    }
    private static func styled(_ text: String, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: bodyFont, .foregroundColor: color, .paragraphStyle: paragraphStyle()])
    }

    /// 太字の範囲を示す目印(私用領域の文字)。CommonMark は「は**「…」**と」のように、日本語や括弧に接した ** を太字と認めないため、
    /// `**…**` はこちらで先に見つけて、目印で囲む。
    private static let boldOpen: Character = "\u{E100}", boldClose: Character = "\u{E101}"
    private static let boldRegex = try? NSRegularExpression(pattern: #"\*\*([^*\n]+?)\*\*"#)

    /// 返信のMarkdownを、見出し→太字、区切り線→空行、**太字**/*斜体*/`コード`、LaTeX の数式→数式の画像 に変えて表示用の文字にする。
    static func markdown(_ text: String) -> NSAttributedString {
        let math = MathTypesetting.extract(from: text)
        let lines = math.text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^(\*{3,}|-{3,}|_{3,})$"#, options: .regularExpression) != nil { return "" }
            if let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                return "**" + trimmed[range.upperBound...].replacingOccurrences(of: "**", with: "") + "**"
            }
            // 箇条書きの `* ` / `- ` は、そのまま記号が見えてしまうので「• 」にする。
            if let range = line.range(of: #"^\s*[*-]\s+"#, options: .regularExpression) {
                let indent = line[..<range.upperBound].prefix { $0 == " " || $0 == "\t" }
                return indent + "• " + line[range.upperBound...]
            }
            return line
        }
        var source = lines.joined(separator: "\n")
        if let regex = boldRegex {
            source = regex.stringByReplacingMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length),
                                                    withTemplate: "\(boldOpen)$1\(boldClose)")
        }
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return styled(source.replacingOccurrences(of: String(boldOpen), with: "").replacingOccurrences(of: String(boldClose), with: ""), color: .label)
        }
        let output = NSMutableAttributedString()
        var bold = false
        for run in parsed.runs {
            var font = bodyFont
            let strong = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular) }
                if intent.contains(.emphasized), let italic = font.fontDescriptor.withSymbolicTraits(.traitItalic) { font = UIFont(descriptor: italic, size: bodySize) }
            }
            // 目印で太字を切り替えながら、1文字ずつではなく、区切りごとにまとめて足す。
            var piece = ""
            func flush() {
                guard !piece.isEmpty else { return }
                let weight = strong || bold
                output.append(NSAttributedString(string: piece, attributes: [.font: weight ? UIFont.systemFont(ofSize: bodySize, weight: .bold) : font, .foregroundColor: UIColor.label]))
                piece = ""
            }
            for character in String(parsed[run.range].characters) {
                if character == boldOpen { flush(); bold = true }
                else if character == boldClose { flush(); bold = false }
                else { piece.append(character) }
            }
            flush()
        }
        output.addAttribute(.paragraphStyle, value: paragraphStyle(), range: NSRange(location: 0, length: output.length))
        let centered = NSMutableParagraphStyle(); centered.setParagraphStyle(paragraphStyle()); centered.alignment = .center
        MathTypesetting.substitute(in: output, spans: math.spans, bodySize: bodySize, centered: centered)
        return output
    }

    // MARK: 秒・token・料金
    static func seconds(_ ms: Double) -> String { String(format: "%.1f秒", ms / 1000) }
    private static func tokensText(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "ja_JP")
        return (f.string(from: NSNumber(value: n)) ?? "\(n)") + " tokens"
    }
    private static func costText(_ usd: Double, usdJPY: Double?) -> String {
        // 円で表示する(1円未満は小数2桁、1円以上は小数1桁)。レートが取れなくても目安レートで円にする。
        let yen = usd * ((usdJPY ?? 0) > 0 ? usdJPY! : defaultUSDJPY)
        return String(format: yen < 1 ? "約¥%.2f" : "約¥%.1f", locale: Locale(identifier: "ja_JP"), yen)
    }

    /// 「回答まで12.3秒 ・ 3,519 tokens ・ 約¥0.5 ⓘ」。取れない項目は出さない(0とは表示しない)。
    /// 秒数は、メッセージを送ってから返答が出そろうまで。
    static func metaLine(_ m: AIReplyMetrics, usdJPY: Double?) -> String {
        var parts: [String] = []
        if let first = m.firstTokenMs { parts.append("最初の文字まで" + seconds(first)) }
        if let ms = m.totalMs { parts.append("回答まで" + seconds(ms)) }
        else {
            if let ms = m.detectMs { parts.append("読み取り" + seconds(ms)) }
            if let ms = m.replyMs { parts.append("返信" + seconds(ms)) }
        }
        let tokens = [m.detectTokens, m.replyTokens].compactMap { $0 }
        if !tokens.isEmpty { parts.append(tokensText(tokens.reduce(0, +))) }
        let costs = [m.detectCostUSD, m.replyCostUSD].compactMap { $0 }
        if !costs.isEmpty { parts.append(costText(costs.reduce(0, +), usdJPY: usdJPY)) }
        return parts.isEmpty ? "" : parts.joined(separator: " ・ ") + "  ⓘ"
    }

    static func detailText(_ m: AIReplyMetrics, usdJPY: Double?) -> String {
        func block(_ title: String, ms: Double?, tokens: Int?, cost: Double?) -> String? {
            var items: [String] = []
            if let ms { items.append(seconds(ms)) }
            if let tokens { items.append(tokensText(tokens)) }
            if let cost { items.append(costText(cost, usdJPY: usdJPY)) }
            return items.isEmpty ? nil : title + ": " + items.joined(separator: " ・ ")
        }
        var lines: [String] = []
        if let total = m.totalMs { lines.append("送信から回答まで: " + seconds(total)) }
        lines += [block("資料の読み取り(サーバー処理)", ms: m.detectMs, tokens: m.detectTokens, cost: m.detectCostUSD),
                  block("返信の作成", ms: m.replyMs, tokens: m.replyTokens, cost: m.replyCostUSD)].compactMap { $0 }
        if let detail = m.detail { lines.append(detail) }
        lines.append("料金は推定値で、円は目安のレート(1ドル=約\(Int(usdJPY ?? defaultUSDJPY))円)での換算です。請求額ではありません。")
        return lines.joined(separator: "\n")
    }

    // MARK: 操作
    @objc private func copyTapped() {
        UIPasteboard.general.string = plainText
        let done = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        let original = copyButton.image(for: .normal)
        copyButton.setImage(done, for: .normal)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyButton.setImage(original, for: .normal) }
    }
    @objc private func shareTapped() {
        guard let presenter = Self.topViewController(from: window?.rootViewController) else { return }
        let sheet = UIActivityViewController(activityItems: [plainText], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        presenter.present(sheet, animated: true)
    }
    private static func topViewController(from root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
    @objc private func toggleDetail() {
        detailVisible.toggle()
        detailLabel.isHidden = !detailVisible
        UIView.animate(withDuration: 0.2) { self.superview?.layoutIfNeeded() }
    }
    @objc private func retryTapped() { onRetry?() }
}


/// 返信の下の「次の候補」。文字を折り返せるように、ボタンではなく、ラベル入りのカプセルにしている。
final class AISuggestionChip: UIControl {
    private let label = UILabel()
    private let onTap: () -> Void

    init(title: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        backgroundColor = UIColor.systemGray5
        layer.cornerRadius = 17
        layer.masksToBounds = true
        label.text = title
        label.font = .systemFont(ofSize: 13)
        label.textColor = .label
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
        accessibilityIdentifier = "ai-suggestion"
        accessibilityLabel = title
        accessibilityTraits = .button
        isAccessibilityElement = true
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
    @objc private func tapped() { onTap() }

    /// 幅 maxWidth の中に置くときの、チップの大きさ。1行に収まれば、文字の幅ぶん。収まらなければ、幅いっぱいで折り返した高さ。
    static func fittingSize(title: String, maxWidth: CGFloat) -> CGSize {
        let font = UIFont.systemFont(ofSize: 13), padding: CGFloat = 28
        let single = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let width = max(padding + 1, min(single + padding, maxWidth))
        let rect = (title as NSString).boundingRect(with: CGSize(width: width - padding, height: CGFloat.greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil)
        return CGSize(width: width, height: ceil(rect.height) + 16)
    }
}

/// チップを、左から横に並べる。入りきらなくなったら、次の行へ(折り返し)。
final class AISuggestionFlowView: UIView {
    private(set) var chips: [AISuggestionChip] = []
    private let spacing: CGFloat = 8
    private var knownWidth: CGFloat = 0

    func setChips(_ new: [AISuggestionChip]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = new
        chips.forEach { addSubview($0) }
        setNeedsLayout(); invalidateIntrinsicContentSize()
    }

    private func arrange(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for chip in chips {
            let size = AISuggestionChip.fittingSize(title: chip.accessibilityLabel ?? "", maxWidth: width)
            if x > 0, x + size.width > width + 0.5 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (frames, chips.isEmpty ? 0 : y + rowHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (frames, height) = arrange(width: bounds.width)
        for (chip, frame) in zip(chips, frames) { chip.frame = frame }
        // 幅が決まったあと(や、変わったとき)に、高さを伝え直す。
        if abs(bounds.width - knownWidth) > 0.5 { knownWidth = bounds.width; invalidateIntrinsicContentSize() }
        else if abs(height - intrinsicContentSize.height) > 0.5 { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: arrange(width: knownWidth > 0 ? knownWidth : 300).height)
    }
}
