//
//  LectureTranscriber.swift
//  Aogaku
//
//  授業AI: Groq Whisperを優先し、利用できない場合のみ端末内認識へフォールバックする。
//

import Foundation
@preconcurrency import AVFoundation
import Speech
import FirebaseAuth
import FirebaseFunctions
import FirebaseStorage

final class LectureTranscriber {

    struct QualitySummary: Codable {
        let segmentCount: Int
        let suspiciousSegmentCount: Int
        let averageLogProbability: Double?
        let highNoSpeechSegmentCount: Int
        let highCompressionSegmentCount: Int

        init?(dictionary: [String: Any]?) {
            guard let dictionary else { return nil }
            segmentCount = dictionary["segmentCount"] as? Int ?? 0
            suspiciousSegmentCount = dictionary["suspiciousSegmentCount"] as? Int ?? 0
            averageLogProbability = dictionary["averageLogProbability"] as? Double
            highNoSpeechSegmentCount = dictionary["highNoSpeechSegmentCount"] as? Int ?? 0
            highCompressionSegmentCount = dictionary["highCompressionSegmentCount"] as? Int ?? 0
        }

        var dictionary: [String: Any] {
            var result: [String: Any] = [
                "segmentCount": segmentCount,
                "suspiciousSegmentCount": suspiciousSegmentCount,
                "highNoSpeechSegmentCount": highNoSpeechSegmentCount,
                "highCompressionSegmentCount": highCompressionSegmentCount
            ]
            if let averageLogProbability {
                result["averageLogProbability"] = averageLogProbability
            }
            return result
        }
    }

    struct ResultValue {
        let rawTranscript: String
        let cleanedTranscript: String
        let model: String
        let chunkCount: Int
        let accurateChunkCount: Int
        let openAIFallbackChunkCount: Int
        let retryImprovedChunkCount: Int
        let turboQuality: QualitySummary?
        let finalQuality: QualitySummary?

        static func onDevice(text: String) -> ResultValue {
            ResultValue(
                rawTranscript: text,
                cleanedTranscript: text,
                model: "apple-speech",
                chunkCount: 0,
                accurateChunkCount: 0,
                openAIFallbackChunkCount: 0,
                retryImprovedChunkCount: 0,
                turboQuality: nil,
                finalQuality: nil
            )
        }
    }

    private struct CloudChunk {
        let url: URL
        let duration: TimeInterval
        let isTemporary: Bool
    }

    private final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession

        init(_ value: AVAssetExportSession) {
            self.value = value
        }
    }

    static let maximumDuration: TimeInterval = 90 * 60
    private static let cloudChunkDuration: TimeInterval = 15 * 60
    private static let cloudChunkOverlap: TimeInterval = 2
    private static let silenceSearchRadius: TimeInterval = 10
    private static let silenceWindowDuration: TimeInterval = 0.25

    enum Stage: Equatable {
        case preparing
        case uploading(progress: Double)
        case transcribing
        case onDeviceFallback
    }

    enum TranscriberError: LocalizedError {
        case cancelled
        case durationExceeded
        case emptyResult
        case notSignedIn
        case permissionDenied
        case recognizerUnavailable
        case preparationFailed

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "文字起こしを中止しました"
            case .durationExceeded:
                return "録音は1回90分以内にしてください"
            case .emptyResult:
                return "音声から文字を読み取れませんでした"
            case .notSignedIn:
                return "AI文字起こしにはサインインが必要です"
            case .permissionDenied:
                return "端末内文字起こしを使うには音声認識の許可が必要です"
            case .recognizerUnavailable:
                return "現在、文字起こしを利用できません"
            case .preparationFailed:
                return "録音を文字起こし用に準備できませんでした"
            }
        }
    }

    var onStageChange: ((Stage) -> Void)?

    private lazy var functions = Functions.functions(region: "asia-northeast1")
    private var uploadTask: StorageUploadTask?
    private var currentRecognitionTask: SFSpeechRecognitionTask?
    private var currentExportSession: AVAssetExportSession?
    private var workTask: Task<Void, Never>?
    private var cancelled = false

    func transcribe(
        audioURL: URL,
        durationSeconds: TimeInterval,
        contextPrompt: String = "",
        completion: @escaping (Result<ResultValue, Error>) -> Void
    ) {
        cancel()
        cancelled = false

        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard durationSeconds > 0, durationSeconds <= Self.maximumDuration else {
                    throw TranscriberError.durationExceeded
                }

                await self.report(.preparing)
                let result: ResultValue
                do {
                    result = try await self.transcribeWithGroq(
                        audioURL: audioURL,
                        durationSeconds: durationSeconds,
                        contextPrompt: contextPrompt
                    )
                } catch {
                    guard !self.cancelled, !Task.isCancelled else {
                        throw TranscriberError.cancelled
                    }
                    await self.report(.onDeviceFallback)
                    result = .onDevice(text: try await self.transcribeOnDevice(audioURL: audioURL))
                }

                guard !self.cancelled, !Task.isCancelled else {
                    throw TranscriberError.cancelled
                }
                guard !result.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TranscriberError.emptyResult
                }
                await MainActor.run { completion(.success(result)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    func cancel() {
        cancelled = true
        uploadTask?.cancel()
        uploadTask = nil
        currentRecognitionTask?.cancel()
        currentRecognitionTask = nil
        currentExportSession?.cancelExport()
        currentExportSession = nil
        workTask?.cancel()
        workTask = nil
    }

    private func transcribeWithGroq(
        audioURL: URL,
        durationSeconds: TimeInterval,
        contextPrompt: String
    ) async throws -> ResultValue {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw TranscriberError.notSignedIn
        }

        let chunks = try await makeCloudChunks(
            audioURL: audioURL,
            durationSeconds: durationSeconds
        )
        defer {
            chunks.filter(\.isTemporary).forEach { try? FileManager.default.removeItem(at: $0.url) }
        }

        let uploadID = UUID().uuidString
        let references = chunks.indices.map { index in
            Storage.storage().reference(
                withPath: "users/\(uid)/transcriptionUploads/\(uploadID)-\(index).m4a"
            )
        }

        do {
            for (index, chunk) in chunks.enumerated() {
                let metadata = StorageMetadata()
                metadata.contentType = "audio/mp4"
                metadata.customMetadata = [
                    "durationSeconds": String(Int(ceil(chunk.duration))),
                    "chunkIndex": String(index)
                ]
                try await upload(
                    audioURL: chunk.url,
                    to: references[index],
                    metadata: metadata,
                    completedChunkCount: index,
                    totalChunkCount: chunks.count
                )
                guard !cancelled, !Task.isCancelled else { throw TranscriberError.cancelled }
            }

            await report(.transcribing)
            let callable = functions.httpsCallable("transcribeLectureAudio")
            callable.timeoutInterval = 540
            let result = try await callable.call([
                "storagePaths": references.map(\.fullPath),
                "durationSeconds": Int(ceil(durationSeconds)),
                "chunkOverlapSeconds": chunks.count > 1 ? Int(Self.cloudChunkOverlap) : 0,
                "contextPrompt": contextPrompt
            ])
            guard let data = result.data as? [String: Any] else {
                throw TranscriberError.emptyResult
            }
            let rawTranscript = (data["rawTranscript"] as? String) ?? (data["text"] as? String) ?? ""
            let cleanedTranscript = (data["cleanedTranscript"] as? String) ?? rawTranscript
            guard !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriberError.emptyResult
            }
            for reference in references { try? await delete(reference) }
            return ResultValue(
                rawTranscript: rawTranscript,
                cleanedTranscript: cleanedTranscript,
                model: data["model"] as? String ?? "",
                chunkCount: data["chunkCount"] as? Int ?? chunks.count,
                accurateChunkCount: data["accurateChunkCount"] as? Int ?? 0,
                openAIFallbackChunkCount: data["openAIFallbackChunkCount"] as? Int ?? 0,
                retryImprovedChunkCount: data["retryImprovedChunkCount"] as? Int ?? 0,
                turboQuality: QualitySummary(dictionary: data["turboQuality"] as? [String: Any]),
                finalQuality: QualitySummary(dictionary: data["finalQuality"] as? [String: Any])
            )
        } catch {
            for reference in references { try? await delete(reference) }
            throw error
        }
    }

    private func makeCloudChunks(
        audioURL: URL,
        durationSeconds: TimeInterval
    ) async throws -> [CloudChunk] {
        guard durationSeconds > Self.cloudChunkDuration else {
            return [CloudChunk(url: audioURL, duration: durationSeconds, isTemporary: false)]
        }

        let asset = AVURLAsset(url: audioURL)
        var chunks: [CloudChunk] = []
        do {
            var start: TimeInterval = 0
            while start < durationSeconds {
                guard !cancelled, !Task.isCancelled else { throw TranscriberError.cancelled }
                let nominalEnd = min(start + Self.cloudChunkDuration, durationSeconds)
                let end: TimeInterval
                if nominalEnd < durationSeconds {
                    end = quietBoundary(in: audioURL, around: nominalEnd) ?? nominalEnd
                } else {
                    end = nominalEnd
                }
                guard let url = try await exportChunk(asset: asset, start: start, end: end) else {
                    throw TranscriberError.preparationFailed
                }
                chunks.append(CloudChunk(url: url, duration: end - start, isTemporary: true))
                if end >= durationSeconds { break }
                start = end - Self.cloudChunkOverlap
            }
            return chunks
        } catch {
            chunks.forEach { try? FileManager.default.removeItem(at: $0.url) }
            throw error
        }
    }

    /// Search a small window around the nominal split and choose the quietest RMS frame.
    /// The overlap remains in place as a second line of defense against clipped words.
    private func quietBoundary(in audioURL: URL, around target: TimeInterval) -> TimeInterval? {
        do {
            let file = try AVAudioFile(forReading: audioURL)
            let format = file.processingFormat
            let sampleRate = format.sampleRate
            guard sampleRate > 0 else { return nil }

            let searchStart = max(0, target - Self.silenceSearchRadius)
            let searchDuration = Self.silenceSearchRadius * 2
            let startFrame = AVAudioFramePosition(searchStart * sampleRate)
            let requestedFrames = AVAudioFrameCount(searchDuration * sampleRate)
            guard requestedFrames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requestedFrames)
            else { return nil }

            file.framePosition = min(startFrame, file.length)
            try file.read(into: buffer, frameCount: requestedFrames)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }

            let windowFrames = max(Int(Self.silenceWindowDuration * sampleRate), 1)
            let frameLength = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            var quietestOffset = 0
            var quietestEnergy = Double.greatestFiniteMagnitude

            var offset = 0
            while offset + windowFrames <= frameLength {
                var energy = 0.0
                for channel in 0..<channelCount {
                    let samples = channels[channel]
                    for index in offset..<(offset + windowFrames) {
                        let sample = Double(samples[index])
                        energy += sample * sample
                    }
                }
                energy /= Double(windowFrames * max(channelCount, 1))
                if energy < quietestEnergy {
                    quietestEnergy = energy
                    quietestOffset = offset + windowFrames / 2
                }
                offset += windowFrames
            }

            return searchStart + Double(quietestOffset) / sampleRate
        } catch {
            return nil
        }
    }

    private func upload(
        audioURL: URL,
        to reference: StorageReference,
        metadata: StorageMetadata,
        completedChunkCount: Int,
        totalChunkCount: Int
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            let task = reference.putFile(from: audioURL, metadata: metadata) { [weak self] _, error in
                guard !didResume else { return }
                didResume = true
                self?.uploadTask?.removeAllObservers()
                self?.uploadTask = nil
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            uploadTask = task
            task.observe(.progress) { [weak self] snapshot in
                guard let progress = snapshot.progress else { return }
                let overallProgress = (
                    Double(completedChunkCount) + progress.fractionCompleted
                ) / Double(max(totalChunkCount, 1))
                Task { await self?.report(.uploading(progress: overallProgress)) }
            }
        }
    }

    private func delete(_ reference: StorageReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func report(_ stage: Stage) async {
        await MainActor.run { self.onStageChange?(stage) }
    }

    // MARK: - On-device fallback

    private let chunkDuration: Double = 50

    private func transcribeOnDevice(audioURL: URL) async throws -> String {
        let permissionGranted = await requestSpeechPermission()
        guard permissionGranted else { throw TranscriberError.permissionDenied }

        let asset = AVURLAsset(url: audioURL)
        let durationSeconds = try await asset.load(.duration).seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { return "" }

        var results: [String] = []
        var start: Double = 0
        while start < durationSeconds {
            guard !cancelled, !Task.isCancelled else { throw TranscriberError.cancelled }
            let end = min(start + chunkDuration, durationSeconds)
            if let chunkURL = try await exportChunk(asset: asset, start: start, end: end) {
                defer { try? FileManager.default.removeItem(at: chunkURL) }
                if let text = try? await recognizeChunk(url: chunkURL), !text.isEmpty {
                    results.append(text)
                }
            }
            start = end
        }
        return results.joined(separator: " ")
    }

    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func exportChunk(asset: AVURLAsset, start: Double, end: Double) async throws -> URL? {
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            return nil
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )

        let exportBox = ExportSessionBox(exportSession)
        currentExportSession = exportSession
        let exportedURL: URL? = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL?, Error>) in
            exportBox.value.exportAsynchronously {
                switch exportBox.value.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .failed, .cancelled:
                    continuation.resume(
                        throwing: exportBox.value.error ?? TranscriberError.recognizerUnavailable
                    )
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
        currentExportSession = nil
        return exportedURL
    }

    private func recognizeChunk(url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")),
                  recognizer.isAvailable else {
                continuation.resume(throwing: TranscriberError.recognizerUnavailable)
                return
            }

            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            var didResume = false
            currentRecognitionTask = recognizer.recognitionTask(with: request) { result, error in
                guard !didResume else { return }
                if let error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                didResume = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }
}
