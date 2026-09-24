//
//  ReactionPaperService.swift
//  Aogaku
//
//  授業ノート(AI)機能: 録音・撮影・シラバス概要から指定文字数のテキストを生成する(Cloud Functions経由)
//

import Foundation
import FirebaseFunctions

enum ReactionPaperServiceError: LocalizedError {
    case emptyResult
    var errorDescription: String? {
        switch self {
        case .emptyResult: return "生成結果を取得できませんでした"
        }
    }
}

final class ReactionPaperService {
    static let shared = ReactionPaperService()
    private lazy var functions = Functions.functions(region: "asia-northeast1")

    func generate(
        transcript: String,
        photoText: String,
        syllabusOverview: String,
        assignmentInstructions: String,
        personalNotes: String,
        targetLength: Int
    ) async throws -> String {
        let callable = functions.httpsCallable("generateReactionPaper")
        let result = try await callable.call([
            "transcript": transcript,
            "photoText": photoText,
            "syllabusOverview": syllabusOverview,
            "assignmentInstructions": assignmentInstructions,
            "personalNotes": personalNotes,
            "targetLength": targetLength
        ])
        guard let dict = result.data as? [String: Any], let text = dict["text"] as? String, !text.isEmpty else {
            throw ReactionPaperServiceError.emptyResult
        }
        return text
    }
}
