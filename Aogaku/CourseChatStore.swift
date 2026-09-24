//
//  CourseChatStore.swift
//  Aogaku
//
//  授業AIチャットの会話ログ: Firestore からの取得(users/{uid}/courseChats/{courseKey}/messages)
//  書き込みはaskCourseAI(Cloud Functions)側で行うため、ここでは読み取りのみ扱う。
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

enum CourseChatRole: String {
    case user
    case assistant
}

struct CourseChatMessage: Identifiable {
    var id: String
    var role: CourseChatRole
    var content: String
    var createdAt: Date

    init?(doc: DocumentSnapshot) {
        guard let d = doc.data(),
              let roleRaw = d["role"] as? String,
              let role = CourseChatRole(rawValue: roleRaw),
              let content = d["content"] as? String
        else { return nil }

        self.id = doc.documentID
        self.role = role
        self.content = content
        self.createdAt = (d["createdAt"] as? Timestamp)?.dateValue() ?? Date()
    }
}

enum CourseChatStoreError: Error {
    case notSignedIn
}

final class CourseChatStore {

    static let shared = CourseChatStore()
    private let db = Firestore.firestore()

    private func messagesCollection(courseKey: String) throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw CourseChatStoreError.notSignedIn
        }
        return db.collection("users").document(uid)
            .collection("courseChats").document(courseKey)
            .collection("messages")
    }

    func fetchMessages(courseKey: String) async throws -> [CourseChatMessage] {
        let collection = try messagesCollection(courseKey: courseKey)
        let snapshot = try await collection
            .order(by: "createdAt", descending: false)
            .getDocuments()
        return snapshot.documents.compactMap { CourseChatMessage(doc: $0) }
    }
}
