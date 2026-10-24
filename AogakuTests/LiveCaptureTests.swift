import XCTest
import AVFoundation
@testable import Aogaku

/// 実際のマイクからの取り込み。マイクが使えない環境(権限なし・入力なし)では、スキップする。
final class LiveCaptureTests: XCTestCase {
    func testCapturesFromTheRealMicrophoneIntoSegmentsAndAFullFile() throws {
        let permission = AVAudioApplication.shared.recordPermission
        try XCTSkipIf(permission != .granted, "マイクの権限が無い環境(\(permission.rawValue))")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = AVAudioSession.sharedInstance()
        do { try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker]); try session.setActive(true) }
        catch { throw XCTSkip("音声セッションを開始できない環境: \(error)") }
        var emitted: [LiveSegmentFile] = []
        let lock = NSLock()
        let writer = try AudioSegmentWriter(directory: dir, fullURL: dir.appendingPathComponent("full.m4a"), segmentSeconds: 1) { lock.lock(); emitted.append($0); lock.unlock() }
        let capture = LiveCapture(writer: writer)
        do { try capture.start() } catch { throw XCTSkip("マイクを開始できない環境: \(error)") }
        Thread.sleep(forTimeInterval: 3.4)
        let (duration, count) = capture.stop()
        XCTAssertGreaterThan(duration, 2.5, "取り込んだ長さ")
        XCTAssertLessThan(duration, 4.5)
        XCTAssertGreaterThanOrEqual(count, 3, "1秒ごとの区間が出る")
        lock.lock(); let files = emitted; lock.unlock()
        XCTAssertEqual(files.count, count)
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path)) }
        let full = try AVAudioFile(forReading: dir.appendingPathComponent("full.m4a"))
        XCTAssertEqual(Double(full.length) / full.processingFormat.sampleRate, duration, accuracy: 0.3)
    }
}
