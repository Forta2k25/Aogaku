import Foundation
import FirebaseCore
import FirebaseAuth

/// Debug defaults to local UI only. A missing or mismatched configuration never falls back to production.
enum AppBackend {
    static var configurationError: String?
    static var isOffline: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["AOGAKU_BACKEND"] != "development"
        #else
        return false
        #endif
    }
    static var currentUID: String? {
        if configurationError != nil { return nil }
        if isOffline { return "local-ai-preview-v1" }
        return Auth.auth().currentUser?.uid
    }
    static func configureFirebase() throws {
        #if DEBUG
        let role = "development"
        #else
        let role = "production"
        #endif
        guard let manifestURL = Bundle.main.url(forResource: "FirebaseEnvironment", withExtension: "plist"),
              let manifest = NSDictionary(contentsOf: manifestURL), manifest["role"] as? String == role,
              let expected = manifest["projectID"] as? String,
              let path = Bundle.main.path(forResource: "GoogleService-Info-\(role)", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path), options.projectID == expected,
              options.bundleID == Bundle.main.bundleIdentifier else {
            throw AIInputError.message("\(role)用のFirebase設定が未登録、または環境が一致しません。設定手順を確認してください")
        }
        #if DEBUG
        guard options.projectID == "forta-aogaku-dev" else {
            throw AIInputError.message("Debug接続先はforta-aogaku-devだけに限定されています")
        }
        #endif
        AIAppCheck.prepare() // Install before Firebase; server enforcement stays opt-in.
        FirebaseApp.configure(options: options)
    }
}
