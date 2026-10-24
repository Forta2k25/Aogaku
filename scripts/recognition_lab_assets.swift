import AppKit
import Foundation
// Five fictional fixtures. Styled notes do not substitute for real handwriting accuracy tests.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for name in ["slide", "handwriting", "arrow", "enclosure", "diagram"] {
    let image = NSImage(size: NSSize(width: 1000, height: 700)); image.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 700).fill()
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 42, _ color: NSColor = .black) {
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }
    text("Recognition Lab - 架空講義", 50, 590, 36)
    switch name {
    case "slide": text("遺伝の基礎", 90, 460); text("親から子へ特徴が伝わる", 90, 350); text("重要語：親・子・遺伝", 90, 240)
    case "handwriting":
        text("細胞の構造", 90, 430); text("核：遺伝情報", 90, 320)
        ("重要！" as NSString).draw(at: NSPoint(x: 520, y: 230), withAttributes: [.font: NSFont(name:"MarkerFelt-Wide",size:48) ?? NSFont.systemFont(ofSize:48), .foregroundColor: NSColor.red])
    case "enclosure":
        text("生物", 340, 450); text("植物", 160, 330); text("動物", 510, 330)
        let box=NSBezierPath(rect:NSRect(x:110,y:300,width:650,height:105));box.lineWidth=4;box.stroke();text("囲みは同じグループ",120,170,34)
    default:
        text("親", 150, 360, 64); text("子", 740, 360, 64); text("遺伝", 430, 230, 44)
        let arrow=NSBezierPath();arrow.lineWidth=6;arrow.move(to:NSPoint(x:260,y:395));arrow.line(to:NSPoint(x:690,y:395));arrow.move(to:NSPoint(x:650,y:420));arrow.line(to:NSPoint(x:690,y:395));arrow.line(to:NSPoint(x:650,y:370));arrow.move(to:NSPoint(x:480,y:290));arrow.line(to:NSPoint(x:480,y:385));arrow.move(to:NSPoint(x:460,y:355));arrow.line(to:NSPoint(x:480,y:385));arrow.line(to:NSPoint(x:500,y:355));arrow.stroke()
        if name=="diagram"{NSBezierPath(ovalIn:NSRect(x:115,y:330,width:130,height:130)).stroke();NSBezierPath(ovalIn:NSRect(x:710,y:330,width:130,height:130)).stroke();text("ラベルと矢印の関係", 180, 100, 34)}
    }
    image.unlockFocus();let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
    try bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.9])!.write(to:directory.appendingPathComponent(name+".jpg"))
}
print("Five synthetic image fixtures generated; no personal data.")
