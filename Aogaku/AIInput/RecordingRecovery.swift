import Foundation
import AVFoundation

/// Written before recording starts, so a terminated process cannot lose the course association.
@MainActor
enum RecordingRecovery {
    struct Receipt: Codable { let context: AIInputContext; let fileURL: URL }
    private static func receiptURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("AIRecordingReceipt.json")
    }
    static func begin(context: AIInputContext, fileURL: URL) throws {
        // Do not overwrite another account's unrecovered recording.
        if let existing = try load(), existing.context.ownerUID != context.ownerUID {
            throw AIInputError.message("前のアカウントの録音を復旧してから録音してください")
        }
        try finish(uid: context.ownerUID)
        try JSONEncoder().encode(Receipt(context: context, fileURL: fileURL)).write(to: receiptURL(), options: .atomic)
    }
    static func load() throws -> Receipt? {
        let url = try receiptURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
    }
    static func erase(uid: String) throws {
        guard let receipt = try load(), receipt.context.ownerUID == uid else { return }
        if FileManager.default.fileExists(atPath: receipt.fileURL.path) { try FileManager.default.removeItem(at: receipt.fileURL) }
        try FileManager.default.removeItem(at: receiptURL())
    }
    @discardableResult
    static func finish(uid: String) throws -> URL? {
        guard let receipt = try load(), receipt.context.ownerUID == uid else { return nil }
        guard FileManager.default.fileExists(atPath: receipt.fileURL.path) else {
            try FileManager.default.removeItem(at: receiptURL()); return nil
        }
        let duration = try AVAudioPlayer(contentsOf: receipt.fileURL).duration
        var savedURL: URL?
        if duration >= 1 {
            let store = try SourceIngestionService.shared.store(uid: uid)
            let source = try store.stage(context: receipt.context, kind: .audio,
                  title: "授業の録音", mime: "audio/mp4", fileURL: receipt.fileURL, duration: duration)
            savedURL = store.fileURL(source)
        }
        try FileManager.default.removeItem(at: receiptURL())
        if savedURL != nil { try? FileManager.default.removeItem(at: receipt.fileURL) }
        return savedURL
    }
}
