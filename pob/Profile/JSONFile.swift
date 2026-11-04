import Foundation

nonisolated struct JSONFile<Value: Codable> {
    let url: URL

    /// nil when the file is missing or unreadable.
    func load() -> Value? {
        loadChecked().value
    }

    /// An unreadable file is logged and copied to `<name>.unreadable`, because the next save replaces it. If the copy
    /// fails, `isReplaceable` is false: the file is then the only place what it holds still exists.
    func loadChecked() -> (value: Value?, isReplaceable: Bool) {
        do {
            return (try read(), true)
        } catch {
            NSLog("Can't read %@: %@", url.lastPathComponent, String(describing: error))
        }
        do {
            try Data(contentsOf: url).write(to: url.appendingPathExtension("unreadable"), options: .atomic)
            return (nil, true)
        } catch {
            NSLog("Can't keep a copy of %@: %@", url.lastPathComponent, String(describing: error))
            return (nil, false)
        }
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
