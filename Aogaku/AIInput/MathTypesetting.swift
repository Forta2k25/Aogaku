import UIKit
import SwiftMath

/// 返信の中の LaTeX 数式($…$ / $$…$$ / \(…\) / \[…\])を取り出し、数式の画像に置き換える。
/// Markdown に渡す前に数式を目印の1文字(私用領域)に置き換えるので、`_` や `*` が斜体などと誤解されない。
/// 変換できない数式や、書きかけ(閉じの `$` がまだ無い)の数式は、元の文字のまま表示する。
enum MathTypesetting {
    struct Span { let latex: String; let display: Bool }

    private static let firstMarker: UInt32 = 0xE200
    private static let maxSpans = 200
    private static let patterns: [(regex: NSRegularExpression, display: Bool)] = {
        let sources: [(String, Bool)] = [
            (#"\$\$([\s\S]+?)\$\$"#, true),
            (#"\\\[([\s\S]+?)\\\]"#, true),
            (#"\\\(([\s\S]+?)\\\)"#, false),
            // 通貨(「$5 と $10」)を数式と誤認しないよう、$ の内側の端に空白がある・直後が数字や英字のものは対象外にする。
            (#"(?<![\\$\w])\$(?!\s)([^$\n]+?)(?<!\s)\$(?![\w$])"#, false),
        ]
        return sources.compactMap { source in (try? NSRegularExpression(pattern: source.0)).map { ($0, source.1) } }
    }()

    /// 数式を目印の文字に置き換えた文章と、数式の一覧(目印の番号順)を返す。
    static func extract(from text: String) -> (text: String, spans: [Span]) {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return (text, []) }
        var result = text, spans: [Span] = []
        for (regex, display) in patterns {
            let source = result as NSString
            var output = "", cursor = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)) {
                guard spans.count < maxSpans, let marker = Unicode.Scalar(firstMarker + UInt32(spans.count)) else { break }
                output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                output += String(Character(marker))
                spans.append(Span(latex: source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines), display: display))
                cursor = match.range.location + match.range.length
            }
            output += source.substring(from: cursor)
            result = output
        }
        return (result, spans)
    }

    /// SwiftMath が知らない、よく使われる記法を、近い記法に言い換える。
    static func normalize(_ latex: String) -> String {
        var value = latex
        for (from, to) in [("\\dotsb", "\\cdots"), ("\\dotsc", "\\ldots"), ("\\dots", "\\ldots"), ("\\boldsymbol", "\\mathbf"), ("\\bm", "\\mathbf"),
                           ("\\operatorname*", "\\mathrm"), ("\\operatorname", "\\mathrm"), ("\\displaystyle", ""), ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac")] {
            value = value.replacingOccurrences(of: from, with: to)
        }
        return value
    }

    private static let cache = NSCache<NSString, UIImage>()
    private static let layoutCache = NSCache<NSString, NSNumber>()

    /// 数式を、文章の高さに合わせた画像つきの文字(NSTextAttachment)にする。変換できなければ nil。
    static func attachment(for span: Span, bodySize: CGFloat) -> NSAttributedString? {
        let size = span.display ? bodySize + 3 : bodySize + 1
        let color = UIColor.label.resolvedColor(with: UITraitCollection.current)
        let key = "\(span.display ? "D" : "I")|\(size)|\(color.hash)|\(span.latex)" as NSString
        var image = cache.object(forKey: key)
        var descent = CGFloat(layoutCache.object(forKey: key)?.doubleValue ?? 0)
        if image == nil {
            var math = MathImage(latex: normalize(span.latex), fontSize: size, textColor: color, labelMode: span.display ? .display : .text)
            let (error, rendered, layout) = math.asImage()
            guard error == nil, let rendered else { return nil }
            image = rendered; descent = layout?.descent ?? 0
            cache.setObject(rendered, forKey: key); layoutCache.setObject(NSNumber(value: Double(descent)), forKey: key)
        }
        guard let image else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        // 文字の下端(ベースライン)に、数式のベースラインを合わせる。
        // 画面より横に長い式は、収まるように縮める(切れて読めなくなるのを防ぐ)。
        let limit = max(120, UIScreen.main.bounds.width - 48), scale = image.size.width > limit ? limit / image.size.width : 1
        attachment.bounds = CGRect(x: 0, y: -descent * scale, width: image.size.width * scale, height: image.size.height * scale)
        return NSAttributedString(attachment: attachment)
    }

    /// 目印の文字を、数式の画像に置き換える。画像にできなかった数式は、元の `$…$` の文字に戻す。
    static func substitute(in output: NSMutableAttributedString, spans: [Span], bodySize: CGFloat, centered: NSParagraphStyle) {
        guard !spans.isEmpty else { return }
        for (index, span) in spans.enumerated().reversed() {
            guard let marker = Unicode.Scalar(firstMarker + UInt32(index)) else { continue }
            let target = String(Character(marker)), range = (output.string as NSString).range(of: target)
            guard range.location != NSNotFound else { continue }
            guard let math = attachment(for: span, bodySize: bodySize) else {
                let raw = span.display ? "$$\(span.latex)$$" : "$\(span.latex)$"
                output.replaceCharacters(in: range, with: NSAttributedString(string: raw, attributes: output.attributes(at: range.location, effectiveRange: nil)))
                continue
            }
            let attributes = output.attributes(at: range.location, effectiveRange: nil)
            let piece = NSMutableAttributedString(attributedString: math)
            piece.addAttributes(attributes.filter { $0.key != .attachment }, range: NSRange(location: 0, length: piece.length))
            if span.display {
                // 独立した式は、前後で改行して、中央に置く。
                let string = output.string as NSString
                let needsBefore = range.location > 0 && string.character(at: range.location - 1) != 10
                let after = range.location + range.length
                let needsAfter = after < string.length && string.character(at: after) != 10
                let wrapped = NSMutableAttributedString()
                if needsBefore { wrapped.append(NSAttributedString(string: "\n", attributes: attributes)) }
                wrapped.append(piece)
                if needsAfter { wrapped.append(NSAttributedString(string: "\n", attributes: attributes)) }
                wrapped.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: wrapped.length))
                output.replaceCharacters(in: range, with: wrapped)
            } else {
                output.replaceCharacters(in: range, with: piece)
            }
        }
    }
}
