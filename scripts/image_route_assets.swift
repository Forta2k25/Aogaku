import AppKit
import Foundation
// Fresh fictional diagrams; run identifier changes the actual pixels and hash.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let run = CommandLine.arguments[2]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for i in 1...2 {
    let image = NSImage(size: NSSize(width: 1400, height: 1000)); image.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1400, height: 1000).fill()
    let text = i == 1 ? "架空講義：植物の成長\n種子 → 発芽 → 成長\n水と光が成長を助ける。矢印は順序を表す。" : "架空講義：検索拡張生成\n質問 → 資料検索 → 出典付き回答\n検索した資料に基づき回答を検証する。"
    (text as NSString).draw(in: NSRect(x: 80,y: 240,width: 1250,height: 650), withAttributes: [.font:NSFont.systemFont(ofSize: 48),.foregroundColor:NSColor.black])
    ("Synthetic run \(run) image \(i)" as NSString).draw(in: NSRect(x: 80,y: 70,width: 1250,height: 100), withAttributes: [.font:NSFont.systemFont(ofSize: 22),.foregroundColor:NSColor.gray])
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95])!.write(to: output.appendingPathComponent("image-\(i).jpg"))
}
