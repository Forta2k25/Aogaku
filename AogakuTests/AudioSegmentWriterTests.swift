import XCTest
import AVFoundation
@testable import Aogaku

final class AudioSegmentWriterTests: XCTestCase {
    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    /// 440Hz の音を、4096フレームずつ(最後は端数)、指定の秒数ぶん書く。
    private func feed(_ writer: AudioSegmentWriter, seconds: Double) throws {
        let rate = AudioSegmentWriter.sampleRate
        var remaining = Int(seconds * rate), phase = 0
        while remaining > 0 {
            let n = min(4096, remaining)
            let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            let data = buffer.floatChannelData![0]
            for i in 0..<n { data[i] = 0.3 * sinf(Float(2 * Double.pi * 440 * Double(phase + i) / rate)) }
            try writer.append(buffer); phase += n; remaining -= n
        }
    }
    private func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func testCutsIntoSegmentsWithoutLosingAudioAndKeepsTheFullFile() throws {
        let dir = try makeDir(), fullURL = dir.appendingPathComponent("full.m4a")
        var emitted: [LiveSegmentFile] = []
        let writer = try AudioSegmentWriter(directory: dir, fullURL: fullURL, segmentSeconds: 2) { emitted.append($0) }
        try feed(writer, seconds: 5.5)
        XCTAssertEqual(emitted.count, 2, "2秒ごとの区間が、書き終わったら出る")
        writer.finish()
        XCTAssertEqual(emitted.map(\.index), [0, 1, 2], "最後の1.5秒も、区間として出る")
        XCTAssertEqual(writer.segmentCount, 3)
        XCTAssertEqual(emitted.map(\.startSeconds), [0, 2, 4])
        XCTAssertEqual(emitted[0].duration, 2, accuracy: 0.01)
        XCTAssertEqual(emitted[2].duration, 1.5, accuracy: 0.01)
        for file in emitted { XCTAssertEqual(try seconds(of: file.url), file.duration, accuracy: 0.15, "区間のファイルが、その長さで読める") }
        XCTAssertEqual(try seconds(of: fullURL), 5.5, accuracy: 0.15, "全体のファイルは、区間の合計と同じ長さ")
        XCTAssertEqual(writer.totalSeconds, 5.5, accuracy: 0.001)
    }

    func testTooShortLastSegmentIsDroppedAndItsFileRemoved() throws {
        let dir = try makeDir()
        var emitted: [LiveSegmentFile] = []
        let writer = try AudioSegmentWriter(directory: dir, fullURL: dir.appendingPathComponent("full.m4a"), segmentSeconds: 2) { emitted.append($0) }
        try feed(writer, seconds: 4.4)
        writer.finish()
        XCTAssertEqual(emitted.count, 2, "0.4秒の端数は、区間にしない")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-002.m4a").path))
    }

    func testBufferLargerThanASegmentIsSplitAcrossSegments() throws {
        let dir = try makeDir()
        var emitted: [LiveSegmentFile] = []
        let writer = try AudioSegmentWriter(directory: dir, fullURL: dir.appendingPathComponent("full.m4a"), segmentSeconds: 1) { emitted.append($0) }
        let n = Int(AudioSegmentWriter.sampleRate * 2.5)   // 1回で2.5秒ぶん
        let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buffer.floatChannelData![0][i] = 0.2 * sinf(Float(i) * 0.05) }
        try writer.append(buffer); writer.finish()
        XCTAssertEqual(emitted.count, 3)
        XCTAssertEqual(emitted.map(\.duration).reduce(0, +), 2.5, accuracy: 0.001)
    }
}
