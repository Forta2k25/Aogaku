//
//  CourseAIService.swift
//  Aogaku
//
//  授業ごとの記録を使って、制限付きの質問・生成をCloud Functionsへ依頼する。
//

import Foundation
import FirebaseFunctions

enum CourseAIServiceError: LocalizedError {
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .emptyResult:
            return "AIの回答を取得できませんでした"
        }
    }
}

final class CourseAIService {
    static let shared = CourseAIService()
    private lazy var functions = Functions.functions(region: "asia-northeast1")

    func ask(
        prompt: String,
        transcript: String,
        photoText: String,
        syllabusOverview: String,
        courseKey: String
    ) async throws -> String {
        let callable = functions.httpsCallable("askCourseAI")
        callable.timeoutInterval = 120
        let result = try await callable.call([
            "prompt": String(prompt.prefix(200)),
            "transcript": transcript,
            "photoText": photoText,
            "syllabusOverview": syllabusOverview,
            "courseKey": courseKey
        ])
        guard let dict = result.data as? [String: Any],
              let text = dict["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CourseAIServiceError.emptyResult
        }
        return text
    }
}
