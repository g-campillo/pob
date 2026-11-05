import Foundation
import WebKit

enum DownloadState: Equatable { case running, finished, failed }

struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let destination: URL
    var state: DownloadState
    var progress: Double
}

/// Every download this run. `WKDownload` quarantines finished files itself.
final class Downloads: NSObject, WKDownloadDelegate {
    /// Owned by the open popover.
    var onChange: (() -> Void)?
    /// Owned by `AppController`. Gets the filename when a download starts.
    var onStart: ((String) -> Void)?
    private(set) var items: [DownloadItem] = []

    private struct Running {
        let id: UUID
        let download: WKDownload // the only strong reference WebKit's download has
        let request: URLRequest?
        let observation: NSKeyValueObservation
    }

    private let directory: URL
    private var running: [ObjectIdentifier: Running] = [:]
    private var requests: [UUID: URLRequest] = [:]
    /// The file doesn't exist until its download writes it, so names handed out are remembered.
    private var claimed: Set<URL> = []
    private var lastNotify = ContinuousClock.Instant.now - .seconds(10)
    private var pendingNotify: Task<Void, Never>?
    /// Progress reaches the popover a few times a second.
    static let notifyInterval: Duration = .milliseconds(250)

    init(directory: URL) {
        self.directory = directory
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let id = UUID()
        let observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted.isFinite ? progress.fractionCompleted : 0
            Task { @MainActor in self?.updateProgress(id, fraction) } // KVO may arrive off the main thread
        }
        running[ObjectIdentifier(download)] = Running(id: id, download: download, request: download.originalRequest, observation: observation)
    }

    func retry(_ id: UUID, in webView: WKWebView) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .failed,
              let request = requests[id] else { return }
        items.remove(at: index)
        requests[id] = nil
        webView.startDownload(using: request) { [weak self] in self?.track($0) }
        notify()
    }

    /// A free name in the folder, kept from other downloads that haven't written yet.
    func destination(for suggestedFilename: String) -> URL {
        let url = Self.safeDestination(directory: directory, suggestedFilename: suggestedFilename, taken: claimed)
        claimed.insert(url)
        return url
    }

    func updateProgress(_ id: UUID, _ fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .running else { return }
        items[index].progress = fraction
        notify(coalescing: true)
    }

    private func notify(coalescing: Bool = false) {
        guard coalescing else {
            pendingNotify?.cancel()
            pendingNotify = nil
            lastNotify = .now
            onChange?()
            return
        }
        let due = lastNotify + Self.notifyInterval
        if ContinuousClock.now >= due {
            notify()
        } else if pendingNotify == nil {
            pendingNotify = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.pendingNotify = nil
                self?.notify()
            }
        }
    }

    private func finish(_ download: WKDownload, as state: DownloadState) {
        guard let entry = running.removeValue(forKey: ObjectIdentifier(download)) else { return }
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else {
            // Failed before any response, so no destination was ever chosen. The row still needs to be there for Retry.
            let name = Self.safeDestination(directory: directory, suggestedFilename: entry.request?.url?.lastPathComponent ?? "").lastPathComponent
            items.append(DownloadItem(id: entry.id, filename: name, destination: directory.appending(path: name), state: .failed, progress: 0))
            requests[entry.id] = entry.request
            notify()
            onStart?(name)
            return
        }
        items[index].state = state
        if state == .finished {
            items[index].progress = 1
        } else {
            discardPartialFile(of: items[index], wroteBytes: entry.download.progress.completedUnitCount > 0)
            claimed.remove(items[index].destination)
        }
        notify()
    }

    /// Only a file this download wrote to. A failure on a path pob doesn't own, such as a dangling symlink, leaves it alone.
    private func discardPartialFile(of item: DownloadItem, wroteBytes: Bool) {
        let path = item.destination.path
        guard wroteBytes, let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType,
              type == .typeRegular else { return }
        try? FileManager.default.removeItem(at: item.destination)
    }

    // MARK: WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        guard let entry = running[ObjectIdentifier(download)] else { return completionHandler(nil) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("pob could not make the downloads folder: \(error)")
            running[ObjectIdentifier(download)] = nil
            return completionHandler(nil)
        }
        let url = destination(for: suggestedFilename)
        items.append(DownloadItem(id: entry.id, filename: url.lastPathComponent, destination: url, state: .running, progress: 0))
        requests[entry.id] = entry.request
        notify()
        onStart?(url.lastPathComponent)
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, as: .finished)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, as: .failed)
    }

    // MARK: Names

    /// The name comes from the server, so it can't leave the folder, hold control or invisible formatting characters
    /// (a right-to-left override disguises an extension) or be too long for the file system.
    static func safeDestination(directory: URL, suggestedFilename: String, taken: Set<URL> = []) -> URL {
        // Split on scalars: a "/" followed by a combining mark is a single Character that a Character split would keep.
        let kept = suggestedFilename.unicodeScalars.filter {
            $0.properties.generalCategory != .control && !$0.properties.isDefaultIgnorableCodePoint
        }
        var name = kept.split { $0 == "/" || $0 == "\\" }.last.map { String(String.UnicodeScalarView($0)) } ?? ""
        if name.isEmpty || name == "." || name == ".." { name = "download" }

        // 255 bytes is the file system's limit. Leave room for " 99999".
        let limit = 249
        var ext = (name as NSString).pathExtension
        if ext.utf8.count > 32 { ext = "" }
        var stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        // A Character is at least a byte, so this bounds the loop below however long the page's name is.
        stem = String(stem.prefix(limit))
        // URLs hand the name back decomposed, which is longer for accented letters, so measure that.
        func bytes(_ text: String) -> Int { text.decomposedStringWithCanonicalMapping.utf8.count }
        while bytes(stem) + bytes(suffix) > limit { stem.removeLast() }

        var candidate = directory.appending(path: stem + suffix, directoryHint: .notDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) || taken.contains(candidate) {
            candidate = directory.appending(path: "\(stem) \(number)\(suffix)", directoryHint: .notDirectory)
            number += 1
        }
        return candidate
    }
}
