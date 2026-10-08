#if DEBUG
import Foundation
import Speech
import AVFoundation

@MainActor
protocol LabAudioRecognitionProvider {
    func recognize(file: URL, onDeviceOnly: Bool) async -> LabRecognitionResult
}
@MainActor
final class AppleLabSpeechRecognizer: LabAudioRecognitionProvider {
    private let authorization: () async -> SFSpeechRecognizerAuthorizationStatus
    init(authorization: @escaping () async -> SFSpeechRecognizerAuthorizationStatus = {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }) { self.authorization = authorization }
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var pending: CheckedContinuation<LabRecognitionResult, Never>?
    private var started = Date()
    private var running = false
    func recognize(file: URL, onDeviceOnly: Bool) async -> LabRecognitionResult {
        let start = Date()
        guard !running else { return .failure("APPLE_ALREADY_RUNNING", method: "apple_speech", provider: "apple", model: "SFSpeechRecognizer ja-JP", started: start) }
        running = true
        defer { running = false }
        let permission = await authorization()
        guard permission == .authorized else { return .failure("APPLE_PERMISSION_DENIED_OR_RESTRICTED", method: "apple_speech", provider: "apple", model: "SFSpeechRecognizer ja-JP", started: start) }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable else {
            return .failure("APPLE_RECOGNIZER_UNAVAILABLE", method: "apple_speech", provider: "apple", model: "SFSpeechRecognizer ja-JP", started: start)
        }
        if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            return .failure("APPLE_ON_DEVICE_UNAVAILABLE", method: "apple_speech", provider: "apple", model: "SFSpeechRecognizer ja-JP", started: start)
        }
        do {
            let duration = try await AVURLAsset(url: file).load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 60 else { throw AIInputError.message("APPLE_LAB_LIMIT_60_SECONDS") }
        } catch { return .failure("APPLE_INVALID_OR_LONG_AUDIO", method: "apple_speech", provider: "apple", model: "SFSpeechRecognizer ja-JP", started: start) }
        if Task.isCancelled { return .failure("APPLE_CANCELLED", method: "apple_speech", provider: "apple", model: "SFSpeechRecognizer ja-JP", started: start) }
        started = start
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending = continuation
                let request = SFSpeechURLRecognitionRequest(url: file)
                request.requiresOnDeviceRecognition = onDeviceOnly
                request.shouldReportPartialResults = false
                recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.pending != nil else { return }
                        if let result, result.isFinal {
                            let segments = result.bestTranscription.segments.map { ["text": $0.substring, "startMs": $0.timestamp * 1000, "endMs": ($0.timestamp + $0.duration) * 1000, "confidence": $0.confidence] as [String: Any] }
                            let data = try? JSONSerialization.data(withJSONObject: ["segments": segments], options: [.sortedKeys])
                            self.finish(LabRecognitionResult(rawText: result.bestTranscription.formattedString, normalizedText: result.bestTranscription.formattedString,
                                structuredResult: data.flatMap { String(data: $0, encoding: .utf8) }, method: "apple_speech", provider: "apple",
                                model: "SFSpeechRecognizer ja-JP \(onDeviceOnly ? "on-device" : "Apple service allowed")", processingMs: Date().timeIntervalSince(start) * 1000,
                                warnings: onDeviceOnly ? [] : ["APPLE_NETWORK_SERVICE_ALLOWED"], error: nil))
                        } else if error != nil { self.fail("APPLE_RECOGNITION_FAILED") }
                    }
                }
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
                    self?.fail("APPLE_TIMEOUT")
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.fail("APPLE_CANCELLED") } }
    }
    private func fail(_ code: String) { finish(.failure(code, method: "apple_speech", provider: "apple", model: "SFSpeechRecognizer ja-JP", started: started)) }
    private func finish(_ result: LabRecognitionResult) {
        guard let continuation = pending else { return }
        pending = nil; timeoutTask?.cancel(); timeoutTask = nil; recognitionTask?.cancel(); recognitionTask = nil
        continuation.resume(returning: result)
    }
}
#endif
