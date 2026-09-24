//
//  LectureRecorder.swift
//  Aogaku
//
//  授業AI: 文字起こし向けに圧縮した音声を端末へ録音する
//

import Foundation
import AVFoundation

final class LectureRecorder: NSObject {

    enum RecorderError: Error {
        case permissionDenied
        case alreadyRecording
        case notRecording
        case failedToStart
    }

    private(set) var noteId: String?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var stoppingManually = false
    private var accumulatedDuration: TimeInterval = 0
    private var activeSegmentStartedAt: TimeInterval?

    var onTick: ((TimeInterval) -> Void)?
    var onMaximumDurationReached: (() -> Void)?

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// 新しい noteId を発行して録音を開始する
    func start(completion: @escaping (Result<String, Error>) -> Void) {
        guard recorder == nil else {
            completion(.failure(RecorderError.alreadyRecording))
            return
        }

        LectureRecorder.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(.failure(RecorderError.permissionDenied))
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                // .mixWithOthers を付けないと、録音開始時に他アプリの音声再生が中断されてしまう
                try session.setCategory(.record, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)

                let noteId = UUID().uuidString
                let url = LectureNote.localAudioURL(noteId: noteId)

                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]

                let rec = try AVAudioRecorder(url: url, settings: settings)
                rec.delegate = self
                rec.isMeteringEnabled = false
                guard rec.record(forDuration: LectureTranscriber.maximumDuration) else {
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                    completion(.failure(RecorderError.failedToStart))
                    return
                }

                self.recorder = rec
                self.noteId = noteId
                self.accumulatedDuration = 0
                self.activeSegmentStartedAt = ProcessInfo.processInfo.systemUptime
                self.startTimer()
                self.onTick?(0)
                completion(.success(noteId))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func pause() {
        captureActiveSegmentDuration()
        recorder?.pause()
        stopTimer()
        onTick?(currentDuration)
    }

    @discardableResult
    func resume() -> Bool {
        guard let recorder else { return false }
        let remaining = LectureTranscriber.maximumDuration - accumulatedDuration
        guard remaining > 0, recorder.record(forDuration: remaining) else { return false }
        activeSegmentStartedAt = ProcessInfo.processInfo.systemUptime
        startTimer()
        return true
    }

    /// 録音を終了し、保存済み音声ファイルのURLを返す
    @discardableResult
    func stop() -> URL? {
        captureActiveSegmentDuration()
        stopTimer()
        let url = recorder?.url
        stoppingManually = true
        recorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recorder = nil
        stoppingManually = false
        return url
    }

    var currentDuration: TimeInterval {
        let activeDuration: TimeInterval
        if let activeSegmentStartedAt {
            activeDuration = ProcessInfo.processInfo.systemUptime - activeSegmentStartedAt
        } else {
            activeDuration = 0
        }
        return min(LectureTranscriber.maximumDuration, accumulatedDuration + activeDuration)
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.recorder != nil else { return }
            self.onTick?(self.currentDuration)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func captureActiveSegmentDuration() {
        guard let activeSegmentStartedAt else { return }
        accumulatedDuration = min(
            LectureTranscriber.maximumDuration,
            accumulatedDuration + ProcessInfo.processInfo.systemUptime - activeSegmentStartedAt
        )
        self.activeSegmentStartedAt = nil
    }
}

extension LectureRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard self.recorder === recorder else { return }
        captureActiveSegmentDuration()
        if flag && !stoppingManually {
            accumulatedDuration = LectureTranscriber.maximumDuration
        }
        stopTimer()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if flag && !stoppingManually {
            DispatchQueue.main.async { [weak self] in self?.onMaximumDurationReached?() }
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        stopTimer()
    }
}
