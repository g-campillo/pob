import Foundation

nonisolated struct TabRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var url: URL?
    var title: String
    var interactionState: Data?

    init(id: UUID = UUID(), url: URL? = nil, title: String = "", interactionState: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.interactionState = interactionState
    }
}

struct TabList: Equatable {
    private(set) var records: [TabRecord]
    private(set) var activeID: UUID?
    private(set) var recentlyClosed: [TabRecord] = []   // newest last, at most 20

    static let recentlyClosedLimit = 20

    var active: TabRecord? { records.first { $0.id == activeID } }

    init(records: [TabRecord] = [], activeID: UUID? = nil) {
        self.records = records
        self.activeID = activeID ?? records.first?.id
    }

    private func index(of id: UUID?) -> Int? { records.firstIndex { $0.id == id } }

    mutating func add(_ record: TabRecord, activate: Bool) {
        records.insert(record, at: index(of: activeID).map { $0 + 1 } ?? records.endIndex)
        if activate || activeID == nil { activeID = record.id }
    }

    mutating func close(_ id: UUID) {
        guard let i = index(of: id) else { return }
        recentlyClosed.append(records.remove(at: i))
        if recentlyClosed.count > Self.recentlyClosedLimit { recentlyClosed.removeFirst() }
        if activeID == id {
            activeID = records.isEmpty ? nil : records[min(i, records.count - 1)].id
        }
    }

    mutating func activate(_ id: UUID) {
        if index(of: id) != nil { activeID = id }
    }

    /// 0 to 7 pick by position, 8 means the last tab, anything else does nothing.
    mutating func activate(index: Int) {
        switch index {
        case 0..<8 where index < records.count: activeID = records[index].id
        case 8 where !records.isEmpty: activeID = records.last?.id
        default: break
        }
    }

    mutating func activateNext() { step(1) }
    mutating func activatePrevious() { step(-1) }

    private mutating func step(_ delta: Int) {
        guard let i = index(of: activeID) else { return }
        activeID = records[(i + delta + records.count) % records.count].id
    }

    mutating func move(from: Int, to: Int) {
        guard records.indices.contains(from), records.indices.contains(to) else { return }
        records.insert(records.remove(at: from), at: to)
    }

    mutating func reopenLast() -> TabRecord? {
        guard let record = recentlyClosed.popLast() else { return nil }
        add(record, activate: true)
        return record
    }

    mutating func update(_ id: UUID, _ change: (inout TabRecord) -> Void) {
        guard let i = index(of: id) else { return }
        change(&records[i])
    }
}
