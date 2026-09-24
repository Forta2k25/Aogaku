//
//  LectureNoteStore.swift
//  Aogaku
//
//  授業ノート機能: Firestore への保存・取得(users/{uid}/lectureNotes)
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

enum LectureNoteStoreError: Error {
    case notSignedIn
}

final class LectureNoteStore {

    static let shared = LectureNoteStore()
    private let db = Firestore.firestore()

    private func notesCollection() throws -> CollectionReference {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw LectureNoteStoreError.notSignedIn
        }
        return db.collection("users").document(uid).collection("lectureNotes")
    }

    func save(_ note: LectureNote) async throws {
        let collection = try notesCollection()
        try await collection.document(note.id).setData(note.asDictionary())
    }

    func fetchNotes(courseKey: String) async throws -> [LectureNote] {
        let collection = try notesCollection()
        let snapshot = try await collection
            .whereField("courseKey", isEqualTo: courseKey)
            .getDocuments()
        let notes = snapshot.documents.compactMap { LectureNote(doc: $0) }
        return notes.sorted { $0.lectureDate > $1.lectureDate }
    }

    func delete(noteId: String) async throws {
        let collection = try notesCollection()
        try await collection.document(noteId).delete()
    }
}
