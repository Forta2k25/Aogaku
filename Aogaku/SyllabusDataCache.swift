// SyllabusDataCache.swift
// 抽出済みシラバスフィールド ([String: String]) をローカルに永続キャッシュする。
// キャッシュキーは course.id（時間割登録コード）を使用。
// ファイルは Caches/SyllabusFields/<key>.json に保存する。

import Foundation

final class SyllabusDataCache {

    static let shared = SyllabusDataCache()
    private init() {}

    // MARK: - Directory

    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir  = base.appendingPathComponent("SyllabusFields", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for key: String) -> URL {
        // キーをファイル名として安全な文字列に変換
        let safe = key
            .replacingOccurrences(of: "[^a-zA-Z0-9_\\-]", with: "_", options: .regularExpression)
            .prefix(120)
        return cacheDir.appendingPathComponent("\(safe).json")
    }

    // MARK: - Public API

    /// キャッシュから読み込む。存在しない場合は nil を返す。
    func load(for key: String) -> [String: String]? {
        guard !key.isEmpty else { return nil }
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// 辞書をキャッシュに保存する。
    func save(_ fields: [String: String], for key: String) {
        guard !key.isEmpty, !fields.isEmpty else { return }
        let url = fileURL(for: key)
        guard let data = try? JSONEncoder().encode(fields) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 特定コースのキャッシュを削除する（手動リフレッシュ用）。
    func clear(for key: String) {
        guard !key.isEmpty else { return }
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// キャッシュが存在するか確認する。
    func exists(for key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: fileURL(for: key).path)
    }
}
