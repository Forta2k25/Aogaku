import AVFoundation
import CryptoKit

/// ライブ録音の保存先。アカウントごとに分け、LocalSourceStore の台帳とは別のフォルダ(live/)に置く(台帳の掃除の対象にならない)。
enum LiveRecordingPaths {
    static func root(uid: String, base: URL? = nil) throws -> URL {
        let base = try base ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let key = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = base.appendingPathComponent("AIInput/\(key)/live", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func directory(uid: String, recordingID: String, base: URL? = nil) throws -> URL {
        let url = try root(uid: uid, base: base).appendingPathComponent(recordingID, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 録音の1区間(ふつうは1分)。
struct LiveSegmentFile: Equatable, Sendable {
    let index: Int
    let url: URL
    let startSeconds: Double
    let duration: Double
}

/// 取り込んだ音を、(1) 全体の1ファイルと (2) 1分ごとの区間のファイルに、同時に書く。区間の切れ目で音が欠けないよう、同じ音を途切れなく切り分ける。
/// すべての呼び出しは、1本のキュー(呼び出し側が保証)で行う。
final class AudioSegmentWriter: @unchecked Sendable {
    static let sampleRate: Double = 22050
    /// 最後の区間が、これより短いときは捨てる(サーバーが受け付ける最小の長さ0.5秒に合わせる)。
    static let minimumLastSegmentSeconds: Double = 0.5

    let processingFormat: AVAudioFormat
    private let directory: URL
    private let fullURL: URL
    private let segmentFrames: AVAudioFramePosition
    private let onSegment: (LiveSegmentFile) -> Void
    private var full: AVAudioFile?
    private var segment: AVAudioFile?
    private var segmentURL: URL?
    private(set) var segmentCount = 0
    private var framesInSegment: AVAudioFramePosition = 0
    private var segmentStartFrames: AVAudioFramePosition = 0
    private(set) var totalFrames: AVAudioFramePosition = 0

    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]

    init(directory: URL, fullURL: URL, segmentSeconds: Double = 60, onSegment: @escaping (LiveSegmentFile) -> Void) throws {
        self.directory = directory; self.fullURL = fullURL; self.onSegment = onSegment
        segmentFrames = AVAudioFramePosition(segmentSeconds * Self.sampleRate)
        full = try AVAudioFile(forWriting: fullURL, settings: Self.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = full?.processingFormat else { throw AIInputError.message("録音の形式を準備できませんでした") }
        processingFormat = format
    }

    var totalSeconds: Double { Double(totalFrames) / Self.sampleRate }

    /// 22.05kHz・モノラルの音を足す。区間の長さを超えるときは、そこで区切って、次の区間に続きを書く。
    func append(_ buffer: AVAudioPCMBuffer) throws {
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            if segment == nil { try openSegment() }
            let room = AVAudioFrameCount(max(1, segmentFrames - framesInSegment))
            let count = min(buffer.frameLength - offset, room)
            let piece = offset == 0 && count == buffer.frameLength ? buffer : try slice(buffer, from: offset, count: count)
            try full?.write(from: piece)
            try segment?.write(from: piece)
            framesInSegment += AVAudioFramePosition(count); totalFrames += AVAudioFramePosition(count); offset += count
            if framesInSegment >= segmentFrames { closeSegment(emit: true) }
        }
    }

    /// 録音を終える。ファイルを閉じ、最後の区間(0.5秒以上)を出す。
    func finish() {
        closeSegment(emit: Double(framesInSegment) / Self.sampleRate >= Self.minimumLastSegmentSeconds)
        if framesInSegment > 0, let url = segmentURL { try? FileManager.default.removeItem(at: url); segmentURL = nil }
        full = nil
    }

    private func openSegment() throws {
        let url = directory.appendingPathComponent(String(format: "seg-%03d.m4a", segmentCount))
        segment = try AVAudioFile(forWriting: url, settings: Self.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        segmentURL = url; framesInSegment = 0; segmentStartFrames = totalFrames
    }

    private func closeSegment(emit: Bool) {
        guard segment != nil, let url = segmentURL else { return }
        segment = nil   // AVAudioFile は、解放されたときにファイルを閉じる
        let frames = framesInSegment
        if emit, frames > 0 {
            let file = LiveSegmentFile(index: segmentCount, url: url, startSeconds: Double(segmentStartFrames) / Self.sampleRate, duration: Double(frames) / Self.sampleRate)
            segmentCount += 1; segmentURL = nil; framesInSegment = 0
            onSegment(file)
        }
    }

    private func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFrameCount, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let piece = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let source = buffer.floatChannelData, let destination = piece.floatChannelData else { throw AIInputError.message("録音の音を切り分けられませんでした") }
        for channel in 0..<Int(buffer.format.channelCount) { memcpy(destination[channel], source[channel] + Int(start), Int(count) * MemoryLayout<Float>.size) }
        piece.frameLength = count
        return piece
    }
}

/// マイクの音を、AVAudioEngine で取り込んで、AudioSegmentWriter へ渡す。
final class LiveCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let writer: AudioSegmentWriter
    private let queue = DispatchQueue(label: "ai.live.capture")
    private let lock = NSLock()
    private var level: Float = 0
    private var seconds: Double = 0
    private var failed = false
    private var converter: AVAudioConverter?
    private(set) var isRunning = false
    /// 取り込みが続けられなくなったとき(ディスクの空きなど)。
    var onFailure: (() -> Void)?

    init(writer: AudioSegmentWriter) { self.writer = writer }

    /// 0...1。波形の表示用。
    var currentLevel: Float { lock.lock(); defer { lock.unlock() }; return level }
    var elapsedSeconds: Double { lock.lock(); defer { lock.unlock() }; return seconds }
    var segmentCount: Int { queue.sync { writer.segmentCount } }

    func start() throws {
        try installTap()
        engine.prepare()
        try engine.start()
        isRunning = true
        NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged), name: .AVAudioEngineConfigurationChange, object: engine)
    }

    private func installTap() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: writer.processingFormat) else { throw AIInputError.message("マイクの形式を読み取れませんでした") }
        self.converter = converter
        let outFormat = writer.processingFormat
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if consumed { inputStatus.pointee = .noDataNow; return nil }
                consumed = true; inputStatus.pointee = .haveData; return buffer
            }
            guard status != .error, out.frameLength > 0 else { return }
            let level = Self.level(of: out)
            self.queue.async {
                guard !self.failed else { return }
                do { try self.writer.append(out) } catch {
                    self.failed = true
                    DispatchQueue.main.async { self.onFailure?() }
                    return
                }
                self.lock.lock(); self.level = level; self.seconds = self.writer.totalSeconds; self.lock.unlock()
            }
        }
    }

    /// 他のアプリやヘッドホンの抜き差しで、エンジンが止まったときは、取り込み直す。
    @objc private func configurationChanged() {
        guard isRunning else { return }
        do { try installTap(); engine.prepare(); try engine.start() }
        catch { DispatchQueue.main.async { [weak self] in self?.onFailure?() } }
    }

    /// 止めて、ファイルを閉じる。全体の長さ(秒)と、区間の数を返す。
    func stop() -> (duration: Double, segmentCount: Int) {
        guard isRunning else { return (elapsedSeconds, queue.sync { writer.segmentCount }) }
        isRunning = false
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return queue.sync { writer.finish(); return (writer.totalSeconds, writer.segmentCount) }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = rms > 0 ? 20 * log10(rms) : -160   // 以前の AVAudioRecorder の表示と同じ換算(-50dBを0、0dBを1)
        return max(0, min(1, (decibels + 50) / 50))
    }
}
