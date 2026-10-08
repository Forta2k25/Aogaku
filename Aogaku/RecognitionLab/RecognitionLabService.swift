#if DEBUG
import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFunctions

enum RecognitionLabAccess {
    static var available: Bool {
        AppBackend.isOffline || (AppBackend.configurationError == nil && FirebaseApp.app()?.options.projectID == "forta-aogaku-dev")
    }
    static var dedicatedLaunch: Bool { ProcessInfo.processInfo.environment["AOGAKU_RECOGNITION_LAB"] == "1" }
}
/// Reuses the Dev session and coalesces concurrent anonymous sign-ins. No credentials in app source.
@MainActor
final class LabDevSession {
    private let currentUID: () -> String?
    private let signIn: () async throws -> String
    private var pending: Task<String, Error>?
    init(currentUID: @escaping () -> String?, signIn: @escaping () async throws -> String) {
        self.currentUID = currentUID; self.signIn = signIn
    }
    func ensure() async throws -> String {
        if let uid = currentUID() { return uid }
        if let pending { return try await pending.value }
        let task = Task { try await signIn() }; pending = task
        defer { pending = nil }
        return try await task.value
    }
}
@MainActor
protocol LabImageRecognitionProvider {
    func recognize(image: Data, mime: String, mode: LabImageMode) async throws -> LabComparison
}
@MainActor
final class LabDevRecognitionProvider: LabImageRecognitionProvider {
    private let session = LabDevSession(currentUID: { Auth.auth().currentUser?.uid }, signIn: {
        try await Auth.auth().signInAnonymously().user.uid
    })
    @discardableResult
    func ensureSession() async throws -> String {
        guard !AppBackend.isOffline, AppBackend.configurationError == nil,
              let app = FirebaseApp.app(), app.options.projectID == "forta-aogaku-dev",
              app.options.bundleID == "com.forta2k25.Aogaku.dev" else {
            throw AIInputError.message("Vision / GroqはDev Schemeで実行してください。Apple Speechはログイン不要です。")
        }
        do { return try await session.ensure() }
        catch { throw AIInputError.message("Devの自動匿名認証に失敗しました。DevのAnonymous認証設定と通信を確認してください。") }
    }
    private func call(_ payload: [String: Any]) async throws -> Data {
        try await ensureSession()
        guard let app = FirebaseApp.app() else { throw AIInputError.message("Dev設定がありません") }
        let functions = Functions.functions(app: app, region: "asia-northeast1")
        let callable = functions.httpsCallable("recognitionLabRun"); callable.timeoutInterval = 180
        let response: HTTPSCallableResult
        do { response = try await callable.call(payload) }
        catch {
            let failure = error as NSError
            if failure.domain == FunctionsErrorDomain && failure.code == FunctionsErrorCode.permissionDenied.rawValue {
                throw AIInputError.message("この端末はLab未登録です。「端末UIDをコピー」からDevのLab許可リストへ登録してください。")
            }
            throw error
        }
        return try JSONSerialization.data(withJSONObject: response.data)
    }
    func recognize(image: Data, mime: String, mode: LabImageMode) async throws -> LabComparison {
        guard image.count <= 3 * 1024 * 1024 else { throw AIInputError.message("Labは画像3MB以下です") }
        return try JSONDecoder().decode(LabComparison.self, from: await call(["kind": "image", "mode": mode.rawValue, "mime": mime, "base64": image.base64EncodedString()]))
    }
    func audio(_ bytes: Data, mime: String) async throws -> LabRecognitionResult {
        guard bytes.count <= 3 * 1024 * 1024 else { throw AIInputError.message("Labは音声3MB・60秒以下です") }
        let comparison = try JSONDecoder().decode(LabComparison.self, from: await call(["kind": "audio", "mode": "groq_asr", "mime": mime, "base64": bytes.base64EncodedString()]))
        guard let result = comparison.results.first else { throw AIInputError.message("音声結果がありません") }
        return result
    }
    func capabilities() async throws -> String {
        let data = try await call(["kind": "capabilities"])
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return "Vision: \(value["imageModel"] ?? "?") / 利用可能: \(value["visionAvailable"] ?? false)\nASR: \(value["audioModel"] ?? "?") / 利用可能: \(value["audioAvailable"] ?? false)"
    }
}
#endif
