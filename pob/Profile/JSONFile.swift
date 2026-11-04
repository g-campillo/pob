import Foundation

nonisolated struct JSONFile<Value: Codable> {
    let url: URL

    /// nil when the file is missing or unreadable.
    func load() -> Value? {
        try? read()
    }

    /// nil when the file is missing. Throws when it's there but can't be read or decoded.
    func read() throws -> Value? {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
