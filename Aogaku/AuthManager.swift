import Foundation
import FirebaseAuth
import FirebaseFirestore

enum AuthError: LocalizedError {
    case invalidID
    case idAlreadyTaken
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidID: return "IDは3〜24文字の英数字・ピリオド・アンダーバーのみが使えます。"
        case .idAlreadyTaken: return "このIDは既に使われています。別のIDを選んでください。"
        case .unknown: return "エラーが発生しました。しばらくしてからお試しください。"
        }
    }
}

private let kCachedUIDKey = "auth.uid"

extension AuthManager {
    // 成功時に呼ぶ
    private func cacheCurrentUID() {
        if let uid = Auth.auth().currentUser?.uid {
            UserDefaults.standard.set(uid, forKey: kCachedUIDKey)
        }
    }
    private func clearCachedUID() {
        UserDefaults.standard.removeObject(forKey: kCachedUIDKey)
    }
    var cachedUID: String? {
        UserDefaults.standard.string(forKey: kCachedUIDKey)
    }
}

final class AuthManager {
    static let shared = AuthManager()
    private init() {}

    private let db = Firestore.firestore()

    // 擬似メール生成（ユーザーには見せない）
    private func pseudoEmail(from id: String) -> String { "\(id.lowercased())@aogaku.app" }

    // IDバリデーション: 英数字・ピリオド・アンダーバー、3〜24
    private func isValidID(_ id: String) -> Bool {
        let pattern = "^[A-Za-z0-9._]{3,24}$"
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    // FirebaseAuth のエラーを自前エラーへ
    private func mapAuthError(_ error: Error) -> AuthError {
        let ns = error as NSError
        if ns.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: ns.code) {
            switch code {
            case .operationNotAllowed: return .unknown
            case .emailAlreadyInUse:   return .idAlreadyTaken
            case .weakPassword:        return .unknown
            case .networkError:        return .unknown
            default:                   return .unknown
            }
        }
        return .unknown
    }

    // MARK: - Sign Up（学年・学部学科 つき）
    /// - Parameters:
    ///   - grade: 1〜4
    ///   - faculty: 学部名
    ///   - department: 学科名
    func signUp(id rawID: String,
                password: String,
                grade: Int,
                faculty: String,
                department: String) async throws {

        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidID(id) else { throw AuthError.invalidID }

        // 1) Authユーザー作成
        let email = pseudoEmail(from: id)
        let result: AuthDataResult
        do {
            result = try await Auth.auth().createUser(withEmail: email, password: password)
        } catch {
            throw mapAuthError(error)
        }
        let uid = result.user.uid

        // 2) Firestoreトランザクションで username 予約 + users 初期化（学年/学部学科 含む）
        do {
            let usernameRef = db.collection("usernames").document(id.lowercased())
            let userRef     = db.collection("users").document(uid)

            _ = try await db.runTransaction { txn, errorPointer -> Any? in
                do {
                    let snap = try txn.getDocument(usernameRef)
                    if snap.exists {
                        errorPointer?.pointee = NSError(
                            domain: "AogakuAuth", code: 409,
                            userInfo: [NSLocalizedDescriptionKey: "ID already taken"]
                        )
                        return nil
                    }

                    txn.setData([
                        "uid": uid,
                        "createdAt": FieldValue.serverTimestamp()
                    ], forDocument: usernameRef)

                    txn.setData([
                        "uid": uid,
                        "id": id,
                        "grade": grade,                     // ★ 学年
                        "faculty": faculty,                 // ★ 学部
                        "department": department,           // ★ 学科
                        "createdAt": FieldValue.serverTimestamp()
                    ], forDocument: userRef)

                    return nil
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }

            // 3) 表示名に ID をセット（任意）
            let req = result.user.createProfileChangeRequest()
            req.displayName = id
            try await req.commitChanges()
            
            self.cacheCurrentUID() // 追加

        } catch {
            // ロールバック
            try? await result.user.delete()
            let ns = error as NSError
            if ns.domain == "AogakuAuth", ns.code == 409 { throw AuthError.idAlreadyTaken }
            throw error
        }
    }

    // MARK: - Login / Logout
    func login(id rawID: String, password: String) async throws {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidID(id) else { throw AuthError.invalidID }
        do {
            let email = pseudoEmail(from: id)
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
        } catch {
            throw mapAuthError(error)
        }
        self.cacheCurrentUID()
    }

    func logout() throws {
        try Auth.auth().signOut()
        clearCachedUID()
    }

    var currentUserID: String? { Auth.auth().currentUser?.displayName }
    var currentUID: String? { Auth.auth().currentUser?.uid }
}
