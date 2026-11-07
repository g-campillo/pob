import Foundation
import AppKit
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
    /// Owned by `AppController`. Where the question goes when the page's own window is gone or it's in a background tab.
    var frontWindow: (() -> NSWindow?)?
    /// Tests answer the question through this, because a sheet needs a window on screen.
    var alertSeam: ((NSAlert) -> NSApplication.ModalResponse)?
    /// Replaceable so a test can move past the pause after a Cancel.
    var now: () -> Date = { .now }
    private(set) var items: [DownloadItem] = []

    private struct Running {
        let id: UUID
        let download: WKDownload // the only strong reference WebKit's download has
        let request: URLRequest?
        /// Retry is the user asking directly, so it isn't asked about again.
        let confirmed: Bool
        let observation: NSKeyValueObservation
    }

    /// A download waiting on its sheet. Only `settle` ends one, so its completion handler runs exactly once.
    private struct Question {
        let download: WKDownload
        let webView: ObjectIdentifier?
        let suggestedFilename: String
        let completion: @MainActor (URL?) -> Void
        let windowClosed: NSObjectProtocol
    }

    private var questions: [ObjectIdentifier: Question] = [:]
    private var cancelledAt: [ObjectIdentifier: Date] = [:]
    /// Like `Tab.offerToOpen`: after a Cancel, that page's downloads are dropped for this long.
    private static let pause: TimeInterval = 3

    private let directory: URL
    private var running: [ObjectIdentifier: Running] = [:]
    /// What Retry replays. `confirmed` is whether the user was ever asked, so a row made without a question asks on Retry.
    private var requests: [UUID: (request: URLRequest, confirmed: Bool)] = [:]
    /// The file doesn't exist until its download writes it, so names handed out are remembered.
    private var claimed: Set<URL> = []
    private var lastNotify = ContinuousClock.Instant.now - .seconds(10)
    private var pendingNotify: Task<Void, Never>?
    /// Progress reaches the popover a few times a second.
    static let notifyInterval: Duration = .milliseconds(250)

    init(directory: URL) {
        self.directory = directory
    }

    func track(_ download: WKDownload, confirmed: Bool = false) {
        download.delegate = self
        let id = UUID()
        let observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted.isFinite ? progress.fractionCompleted : 0
            Task { @MainActor in self?.updateProgress(id, fraction) } // KVO may arrive off the main thread
        }
        running[ObjectIdentifier(download)] = Running(id: id, download: download, request: download.originalRequest, confirmed: confirmed, observation: observation)
    }

    func retry(_ id: UUID, in webView: WKWebView) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .failed,
              let saved = requests[id] else { return }
        items.remove(at: index)
        requests[id] = nil
        webView.startDownload(using: saved.request) { [weak self] in self?.track($0, confirmed: saved.confirmed) }
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
        guard questions[ObjectIdentifier(download)] == nil else { return } // gone while its sheet was up, so `settle` cancels
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else {
            // Failed before any response, so no destination was ever chosen. The row still needs to be there for Retry.
            let name = Self.safeDestination(directory: directory, suggestedFilename: entry.request?.url?.lastPathComponent ?? "").lastPathComponent
            items.append(DownloadItem(id: entry.id, filename: name, destination: directory.appending(path: name), state: .failed, progress: 0))
            requests[entry.id] = entry.request.map { ($0, entry.confirmed) }
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
        let id = ObjectIdentifier(download)
        guard let entry = running[id] else { return completionHandler(nil) }
        if entry.confirmed { return begin(download, suggestedFilename: suggestedFilename, completionHandler) }

        // One sheet per page, so a page can't stack them, and a Cancel quiets it for a moment.
        let webView = download.webView.map(ObjectIdentifier.init)
        let busy = webView.map { view in questions.values.contains { $0.webView == view } || now().timeIntervalSince(cancelledAt[view] ?? .distantPast) < Self.pause } ?? false
        guard !busy, let window = download.webView?.window ?? frontWindow?() else {
            running[id] = nil
            return completionHandler(nil)
        }

        let name = Self.safeDestination(directory: directory, suggestedFilename: suggestedFilename).lastPathComponent
        let alert = NSAlert()
        // Server names are untrusted and can be huge. The end stays, because that's where the extension is.
        alert.messageText = "Download \"\(name.count > 80 ? name.prefix(40) + "…" + name.suffix(39) : name)\"?"
        // A blob: or data: address has no host, so the page that made it is the one to name.
        alert.informativeText = (download.originalRequest?.url?.host() ?? download.webView?.url?.host()).map { "From \($0)" } ?? ""
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        // AppKit never answers a sheet whose window closes under it.
        let windowClosed = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle(id, .cancel) }
        }
        questions[id] = Question(download: download, webView: webView, suggestedFilename: suggestedFilename, completion: completionHandler, windowClosed: windowClosed)
        if let alertSeam {
            settle(id, alertSeam(alert))
        } else {
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated { self?.settle(id, response) }
            }
        }
    }

    /// Anything but Download cancels, and only a real Cancel starts the pause: a window that closed answers nobody's question.
    private func settle(_ id: ObjectIdentifier, _ response: NSApplication.ModalResponse) {
        guard let question = questions.removeValue(forKey: id) else { return }
        NotificationCenter.default.removeObserver(question.windowClosed)
        if response == .alertSecondButtonReturn, let webView = question.webView { cancelledAt[webView] = now() }
        guard response == .alertFirstButtonReturn, running[id] != nil else {
            running[id] = nil // before WebKit reports the failure, so `finish` adds no row
            return question.completion(nil)
        }
        begin(question.download, suggestedFilename: question.suggestedFilename, question.completion)
    }

    private func begin(_ download: WKDownload, suggestedFilename: String, _ completionHandler: @MainActor (URL?) -> Void) {
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
        requests[entry.id] = entry.request.map { ($0, true) }
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

    /// The name comes from the server, so it can't leave the folder, hold control, line breaking or invisible formatting characters
    /// (a right-to-left override disguises an extension) or be too long for the file system.
    static func safeDestination(directory: URL, suggestedFilename: String, taken: Set<URL> = []) -> URL {
        // Split on scalars: a "/" followed by a combining mark is a single Character that a Character split would keep.
        let kept = suggestedFilename.unicodeScalars.filter {
            ![.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) && !$0.properties.isDefaultIgnorableCodePoint
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
