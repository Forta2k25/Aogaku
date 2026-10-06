import AppKit
import CoreGraphics
import Foundation

// Fictional teaching material only. No user's document, photo, or microphone content.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let text = "AI INPUT E2E TEST\n検索拡張生成 RAG\n根拠資料の出典を保存し、回答を検証する。\nこれは開発環境だけで使う架空の授業資料です。"
let rect = CGRect(x: 0, y: 0, width: 1400, height: 1000)
let image = NSImage(size: rect.size)
image.lockFocus()
NSColor.white.setFill(); rect.fill()
let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:42), .foregroundColor:NSColor.black]
(text as NSString).draw(in: CGRect(x:80,y:200,width:1240,height:680), withAttributes:attributes)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.95])!.write(to:output.appendingPathComponent("sample-photo.jpg"))
var box = rect
let consumer = CGDataConsumer(url:output.appendingPathComponent("sample-document.pdf") as CFURL)!
let pdf = CGContext(consumer:consumer,mediaBox:&box,nil)!
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext:pdf,flipped:false)
NSColor.white.setFill(); rect.fill()
(text as NSString).draw(in:CGRect(x:80,y:200,width:1240,height:680),withAttributes:attributes)
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.beginPDFPage(nil)
pdf.draw(bitmap.cgImage!,in:rect) // Second page deliberately requires OCR.
pdf.endPDFPage();pdf.closePDF()
try "開発環境の音声テストです。検索拡張生成では、根拠資料を検索し、その出典を保存します。回答は資料に基づいて検証します。".write(to:output.appendingPathComponent("speech.txt"),atomically:true,encoding:.utf8)
print("Created fictional image, two-page PDF (text + scanned image), and speech script")
