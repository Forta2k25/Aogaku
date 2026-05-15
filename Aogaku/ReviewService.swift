// ReviewService.swift
// Aogaku

import Foundation
import FirebaseFirestore
import FirebaseAuth

final class ReviewService {

    static let shared = ReviewService()
    private init() {}

    private let db = Firestore.firestore()

    // MARK: - Helpers

    // classReviews/{courseCode}/entries/{uid}
    // courseCode = course.id（コードフィールド）で学期をまたいでも不変
    private func entriesRef(courseCode: String) -> CollectionReference {
        db.collection("classReviews").document(courseCode).collection("entries")
    }

    // MARK: - Fetch

    /// 公開済みレビューをまとめて取得（後期公開用）
    func fetchPublicReviews(courseCode: String,
                            completion: @escaping ([CourseReview]) -> Void) {
        entriesRef(courseCode: courseCode)
            .whereField("isPublic", isEqualTo: true)
            .getDocuments { snap, _ in
                let reviews = snap?.documents.compactMap {
                    CourseReview(documentData: $0.data(), uid: $0.documentID)
                } ?? []
                completion(reviews)
            }
    }

    /// 自分のレビューを取得
    func fetchMyReview(courseCode: String,
                       completion: @escaping (CourseReview?) -> Void) {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(nil); return
        }
        entriesRef(courseCode: courseCode)
            .document(uid)
            .getDocument { snap, _ in
                guard let data = snap?.data() else { completion(nil); return }
                completion(CourseReview(documentData: data, uid: uid))
            }
    }

    // MARK: - Write

    /// レビューを保存（1ユーザー1レビュー保証: documentID = uid）
    func saveReview(_ review: CourseReview,
                    courseCode: String,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        entriesRef(courseCode: courseCode)
            .document(review.uid)
            .setData(review.asDictionary) { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
    }
}
