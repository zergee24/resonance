import Foundation
import SQLite3
import CryptoKit

enum StoreError: LocalizedError {
    case database(String)
    var errorDescription: String? { if case .database(let message) = self { return "本地资料库：\(message)" }; return nil }
}

@MainActor
final class LocalStore {
    let directory: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Resonance", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        for name in ["Audio", "Features", "Sources", "Exports"] {
            try FileManager.default.createDirectory(at: self.directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        guard sqlite3_open_v2(self.directory.appendingPathComponent("library.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS documents (kind TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL, modified REAL NOT NULL, PRIMARY KEY(kind,id))")
    }

    deinit { sqlite3_close(db) }

    func load<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM documents WHERE kind=? ORDER BY modified DESC", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        var values: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            values.append(try JSONDecoder().decode(type, from: data))
        }
        return values
    }

    func save<T: Encodable>(_ value: T, kind: String, id: String) throws {
        let data = try JSONEncoder().encode(value)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO documents(kind,id,body,modified) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body, modified=excluded.modified", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func remove(kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM documents WHERE kind=? AND id=?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func featureURL(id: UUID) -> URL { directory.appendingPathComponent("Features/\(id.uuidString).plist.lzfse") }

    nonisolated static func writeArtifact<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let compressed = try (encoder.encode(value) as NSData).compressed(using: .lzfse)
        try (compressed as Data).write(to: url, options: .atomic)
    }

    nonisolated static func readArtifact<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse)
        return try PropertyListDecoder().decode(type, from: data as Data)
    }

    nonisolated static func audioDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> StoreError {
        .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开资料库")
    }
}
