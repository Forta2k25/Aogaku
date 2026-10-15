import Foundation
import FirebaseAuth
import FirebaseCore

/// No sign-out, email dialog, or UID registration. Existing accounts are preserved.
@MainActor
final class AIInputSession {
    static let shared = AIInputSession(currentUID: { AppBackend.currentUID }, signIn: {
        guard !AppBackend.isOffline, AppBackend.configurationError == nil, FirebaseApp.app() != nil else {
            throw AIInputError.message("接続設定を確認できませんでした")
        }
        return try await Auth.auth().signInAnonymously().user.uid
    })
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
