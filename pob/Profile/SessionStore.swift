import Foundation
import OSLog

nonisolated struct WindowSnapshot: Codable, Equatable {
    var tabs: [TabRecord]
    var activeIndex: Int
    var frame: String

    /// nil when the index is out of range, which `TabList` takes as the first tab.
    var activeID: UUID? { tabs.indices.contains(activeIndex) ? tabs[activeIndex].id : nil }

    /// `setFrame(from:)` throws on a NaN in any field, and this comes from a file that can hold anything.
    var hasFiniteFrame: Bool { frame.split(separator: " ").allSatisfy { Double($0)?.isFinite == true } }
}

nonisolated struct SessionSnapshot: Codable, Equatable {
    var windows: [WindowSnapshot]
}

/// The windows and tabs to bring back at launch. A snapshot holds every page's state, so it can be large: it's only
/// built when a save is due, and it's encoded and written off the main actor.
final class SessionStore {
    private let file: JSONFile<SessionSnapshot>
    /// Serial, so a slow write can't land on top of a newer one.
    private let writes = DispatchQueue(label: "pob.session")
    private var pendingSnapshot: (() -> SessionSnapshot)?
    /// With no tabs yet, an empty snapshot isn't the user emptying the session, and it could replace one that only failed to load.
    private var hasHadTabs = false
    private var isRestoring = false
    /// An unreadable file that couldn't be copied is the only place its tabs still exist.
    private var mustKeepFile = false

    init(file: JSONFile<SessionSnapshot>) {
        self.file = file
    }

    /// Empty when the file is missing or can't be read.
    func load() -> SessionSnapshot {
        let loaded = file.loadChecked()
        let snapshot = loaded.value ?? SessionSnapshot(windows: [])
        hasHadTabs = !snapshot.windows.isEmpty
        mustKeepFile = !loaded.isReplaceable
        return snapshot
    }

    /// Hands the session to `open` with saves held until it returns. An exception, which AppKit swallows during launch,
    /// means it never does. The hold then stays on, so the windows that didn't open aren't saved away.
    func restore(_ open: (SessionSnapshot) -> Void) {
        isRestoring = true
        open(load())
        isRestoring = false
    }

    /// Returns with the snapshot on disk, after any write still running, so it's safe to call at quit.
    func save(_ snapshot: SessionSnapshot) {
        pendingSnapshot = nil
        if let job = writeJob(for: snapshot) {
            writes.sync(execute: job)
        }
    }

    /// The wait runs from the first change, not the last, so a page that keeps changing its title can't hold the save off.
    func saveSoon(_ snapshot: @escaping () -> SessionSnapshot) {
        let isWaiting = pendingSnapshot != nil
        pendingSnapshot = snapshot
        guard !isWaiting else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, let snapshot = pendingSnapshot else { return }
            pendingSnapshot = nil
            if let job = writeJob(for: snapshot()) {
                writes.async(execute: job)
            }
        }
    }

    /// The one way to the file. Without `@Sendable` the job takes the main actor's isolation: it builds clean, then crashes on the queue.
    private func writeJob(for snapshot: SessionSnapshot) -> DispatchWorkItem? {
        guard !isRestoring, !mustKeepFile else { return nil }
        hasHadTabs = hasHadTabs || !snapshot.windows.isEmpty
        guard hasHadTabs else { return nil }
        return DispatchWorkItem { @Sendable [file] in
            do { try file.save(snapshot) } catch {
                Logger(subsystem: "pob", category: "SessionStore").error("Saving the session failed: \(error)")
            }
        }
    }
}
