import Foundation
import Network
import Testing
import WebKit
@testable import pob

/// A loopback HTTP server, so downloads run through real WebKit without the internet.
final class LocalServer {
    enum Reply {
        case body(Data, headers: [String: String] = [:])
        /// Promises `length` bytes (none promised when nil), sends `sent`, then stays silent until `dropConnections()`.
        case stall(sent: Data, length: Int?)
        case redirect(to: String)
    }

    var routes: [String: Reply] = [:]
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { self.serve(connection) }
        }
        self.listener = listener
        await withCheckedContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    guard case .ready = state, !resumed else { return }
                    resumed = true
                    continuation.resume()
                }
            }
            listener.start(queue: .main)
        }
        port = listener.port?.rawValue ?? 0
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func dropConnections() {
        let open = connections
        connections = []
        open.forEach { $0.cancel() }
    }

    /// Each connection is cancelled once, or the network layer logs the second.
    private func close(_ connection: NWConnection) {
        guard let index = connections.firstIndex(where: { $0 === connection }) else { return }
        connections.remove(at: index)
        connection.cancel()
    }

    func stop() {
        dropConnections()
        listener?.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            MainActor.assumeIsolated {
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.reply(to: connection, path: path)
            }
        }
    }

    private func reply(to connection: NWConnection, path: String) {
        var head = "HTTP/1.1 200 OK\r\nConnection: close\r\n"
        switch routes[path] {
        case .body(let body, let headers)?:
            for (key, value) in headers { head += "\(key): \(value)\r\n" }
            head += "Content-Length: \(body.count)\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                MainActor.assumeIsolated { self.close(connection) }
            })
        case .redirect(let target)?:
            connection.send(content: Data("HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in
                MainActor.assumeIsolated { self.close(connection) }
            })
        case .stall(let sent, let length)?:
            head += "Content-Type: application/octet-stream\r\n"
            if let length { head += "Content-Length: \(length)\r\n" }
            head += "\r\n"
            connection.send(content: Data(head.utf8) + sent, completion: .idempotent)
        case nil:
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in
                MainActor.assumeIsolated { self.close(connection) }
            })
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct DownloadsTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Longer than `eventually`, because real downloads cross processes.
    func within(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func server(_ routes: [String: LocalServer.Reply]) async throws -> LocalServer {
        let server = LocalServer()
        server.routes = routes
        try await server.start()
        return server
    }

    // MARK: Names

    @Test func plainNamesAreKept() throws {
        let folder = try directory()
        #expect(Downloads.safeDestination(directory: folder, suggestedFilename: "report.pdf").lastPathComponent == "report.pdf")
    }
    @Test func existingFilesArentOverwritten() throws {
        let folder = try directory()
        try Data().write(to: folder.appending(path: "report.pdf"))
        #expect(Downloads.safeDestination(directory: folder, suggestedFilename: "report.pdf").lastPathComponent == "report 2.pdf")
    }
    @Test(arguments: ["../../.zshrc", "/etc/passwd", "a/b/c.txt", "..\\..\\x.txt", "../\u{301}evil.txt", "..\u{200D}/x", "/\u{FE0F}x"])
    func namesCantEscapeTheFolder(name: String) throws {
        let folder = try directory()
        let result = Downloads.safeDestination(directory: folder, suggestedFilename: name)
        #expect(result.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    }
    @Test(arguments: ["", ".", "..", "/"])
    func emptyNamesGetADefault(name: String) throws {
        let folder = try directory()
        #expect(Downloads.safeDestination(directory: folder, suggestedFilename: name).lastPathComponent == "download")
    }
    @Test func controlCharactersAreStripped() throws {
        let folder = try directory()
        let name = Downloads.safeDestination(directory: folder, suggestedFilename: "a\u{0}b\nc\u{7F}.txt").lastPathComponent
        #expect(name == "abc.txt")
    }
    @Test func lookalikeFormattingCharactersAreStripped() throws {
        let folder = try directory()
        let name = Downloads.safeDestination(directory: folder, suggestedFilename: "report\u{202E}fdp.app").lastPathComponent
        #expect(name == "reportfdp.app")
    }
    @Test func hugeNamesDontFreezeTheMainThread() throws {
        let folder = try directory()
        let start = ContinuousClock.now
        let result = Downloads.safeDestination(directory: folder, suggestedFilename: String(repeating: "é", count: 40_000) + ".pdf")
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(result.pathExtension == "pdf")
    }
    @Test func longNamesAreShortenedKeepingTheExtension() throws {
        let folder = try directory()
        for stem in [String(repeating: "a", count: 400), String(repeating: "é", count: 300)] {
            let result = Downloads.safeDestination(directory: folder, suggestedFilename: stem + ".pdf")
            #expect(result.lastPathComponent.utf8.count <= 255)
            #expect(result.pathExtension == "pdf")
            // The real file system accepts it.
            try Data().write(to: result)
            // and a second one still fits once " 2" is added.
            let second = Downloads.safeDestination(directory: folder, suggestedFilename: stem + ".pdf")
            #expect(second.lastPathComponent.utf8.count <= 255)
            try Data().write(to: second)
        }
    }
    @Test func simultaneousDownloadsOfOneNameDontCollide() throws {
        let downloads = Downloads(directory: try directory())
        let first = downloads.destination(for: "report.pdf")
        let second = downloads.destination(for: "report.pdf")
        #expect(first.lastPathComponent == "report.pdf")
        #expect(second.lastPathComponent == "report 2.pdf")
    }

    @Test func respondsToTheDelegateMethodsWebKitCalls() {
        let downloads = Downloads(directory: FileManager.default.temporaryDirectory)
        for selector in [
            "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:",
            "downloadDidFinish:",
            "download:didFailWithError:resumeData:",
        ] {
            #expect(downloads.responds(to: NSSelectorFromString(selector)), "\(selector)")
        }
    }

    // MARK: Real WebKit

    @Test func startedDownloadLandsInTheFolderWithTheRightBytes() async throws {
        let bytes = Data((0..<5000).map { UInt8($0 % 251) })
        let server = try await server(["/file.bin": .body(bytes, headers: ["Content-Type": "application/octet-stream"])])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        var started: [String] = []
        downloads.onStart = { started.append($0) }

        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }

        #expect(await within { downloads.items.first?.state == .finished })
        let item = try #require(downloads.items.first)
        #expect(item.filename == "file.bin")
        #expect(item.progress == 1)
        #expect(started == ["file.bin"])
        #expect(try Data(contentsOf: item.destination) == bytes)
        #expect(item.destination.deletingLastPathComponent().standardizedFileURL == tab.profile.directory.appending(path: "Downloads").standardizedFileURL)
    }

    @Test func attachmentResponsesDownloadEvenWhenWebKitCouldShowThem() async throws {
        let server = try await server(["/note": .body(Data("hello".utf8), headers: [
            "Content-Type": "text/plain", "Content-Disposition": "attachment; filename=\"note.txt\"",
        ])])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads

        tab.webView.load(URLRequest(url: server.url("/note")))

        #expect(await within { downloads.items.first?.state == .finished })
        let item = try #require(downloads.items.first)
        #expect(item.filename == "note.txt")
        #expect(try String(contentsOf: item.destination, encoding: .utf8) == "hello")
    }

    @Test func plainTextWithoutAttachmentStillShowsInThePage() async throws {
        let server = try await server(["/note": .body(Data("hello".utf8), headers: ["Content-Type": "text/plain"])])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.webView.load(URLRequest(url: server.url("/note"))) }
        #expect(tab.profile.downloads.items.isEmpty)
        #expect(tab.webView.url == server.url("/note"))
    }

    @Test func downloadAttributeLinkDownloads() async throws {
        let page = #"<a id="l" href="/data.bin" download="chosen.bin">get</a>"#
        let server = try await server([
            "/": .body(Data(page.utf8), headers: ["Content-Type": "text/html"]),
            "/data.bin": .body(Data("payload".utf8), headers: ["Content-Type": "application/octet-stream"]),
        ])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        await finishLoading(tab) { tab.webView.load(URLRequest(url: server.url("/"))) }

        _ = try await tab.webView.evaluateJavaScript("document.getElementById('l').click()")

        #expect(await within { downloads.items.first?.state == .finished })
        let item = try #require(downloads.items.first)
        #expect(item.filename == "chosen.bin")
        #expect(try String(contentsOf: item.destination, encoding: .utf8) == "payload")
    }

    @Test func failedDownloadKeepsItsRowAndRetrySucceeds() async throws {
        let server = try await server(["/f.bin": .stall(sent: Data("part".utf8), length: 1_000_000)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        tab.webView.startDownload(using: URLRequest(url: server.url("/f.bin"))) { downloads.track($0) }
        #expect(await within { downloads.items.first?.state == .running })

        server.dropConnections()
        #expect(await within { downloads.items.first?.state == .failed })
        let failed = try #require(downloads.items.first)

        server.routes["/f.bin"] = .body(Data("whole".utf8), headers: ["Content-Type": "application/octet-stream"])
        downloads.retry(failed.id, in: tab.webView)

        #expect(await within { downloads.items.contains { $0.state == .finished } })
        let done = try #require(downloads.items.first { $0.state == .finished })
        #expect(try String(contentsOf: done.destination, encoding: .utf8) == "whole")
    }

    @Test func progressNotificationsAreCoalesced() async throws {
        let server = try await server(["/slow.bin": .stall(sent: Data("part".utf8), length: 1_000_000)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        tab.webView.startDownload(using: URLRequest(url: server.url("/slow.bin"))) { downloads.track($0) }
        #expect(await within { downloads.items.first?.state == .running })
        let id = try #require(downloads.items.first?.id)
        var changes = 0
        downloads.onChange = { changes += 1 }

        for step in 1...200 { downloads.updateProgress(id, Double(step) / 400) }

        #expect(changes <= 1) // 200 updates in a blink
        // The last value still arrives after the pause, and only a few notifications in all.
        #expect(await within { changes >= 1 })
        try await Task.sleep(for: .milliseconds(600))
        #expect(changes <= 3)
    }

    @Test func downloadFromADeadServerKeepsAFailedRowAndRetryKeepsIt() async throws {
        let dead = try await server([:])
        let url = dead.url("/gone.bin")
        dead.stop()
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        var notices: [String] = []
        downloads.onStart = { notices.append($0) }
        tab.webView.startDownload(using: URLRequest(url: url)) { downloads.track($0) }

        #expect(await within { downloads.items.first?.state == .failed })
        #expect(downloads.items.count == 1)
        #expect(downloads.items.first?.filename == "gone.bin")
        #expect(notices == ["gone.bin"])

        downloads.retry(try #require(downloads.items.first).id, in: tab.webView)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await within { downloads.items.count == 1 && downloads.items.first?.state == .failed })
        // and it can be retried again, once the server is back
        #expect(downloads.items.count == 1)
    }

    @Test func failedDownloadDeletesItsPartialFileSoRetryKeepsTheName() async throws {
        let server = try await server(["/f.bin": .stall(sent: Data("part".utf8), length: 1_000_000)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        tab.webView.startDownload(using: URLRequest(url: server.url("/f.bin"))) { downloads.track($0) }
        #expect(await within { downloads.items.first?.state == .running })
        let partial = try #require(downloads.items.first).destination
        #expect(await within { FileManager.default.fileExists(atPath: partial.path) })
        #expect(await within { (downloads.items.first?.progress ?? 0) > 0 })

        server.dropConnections()
        #expect(await within { downloads.items.first?.state == .failed })
        #expect(!FileManager.default.fileExists(atPath: partial.path))

        server.routes["/f.bin"] = .body(Data("whole".utf8), headers: ["Content-Type": "application/octet-stream"])
        downloads.retry(try #require(downloads.items.first).id, in: tab.webView)
        #expect(await within { downloads.items.contains { $0.state == .finished } })
        #expect(downloads.items.first { $0.state == .finished }?.filename == "f.bin")
    }

    @Test func progressComesThroughTheRealObservation() async throws {
        let server = try await server(["/half.bin": .stall(sent: Data(count: 500), length: 1000)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        tab.webView.startDownload(using: URLRequest(url: server.url("/half.bin"))) { downloads.track($0) }
        #expect(await within { abs((downloads.items.first?.progress ?? 0) - 0.5) < 0.01 })
    }

    @Test func attachmentFromAPopupClosesThePopupAndReturnsToTheOpener() async throws {
        let server = try await server(["/a.bin": .body(Data("a".utf8), headers: ["Content-Disposition": "attachment; filename=a.bin"])])
        defer { server.stop() }
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let opener = tabs.newTab(nil, activate: true)
        let popup = try #require(opener.onCreatePopup?(opener.webView.configuration))
        #expect(tabs.activeTab?.webView === popup)

        popup.load(URLRequest(url: server.url("/a.bin")))

        #expect(await within { opener.profile.downloads.items.first?.state == .finished })
        #expect(await within { tabs.activeTab === opener })
        #expect(tabs.list.records.count == 1)
    }

    // MARK: Chrome

    @Test func railHasALabelledDownloadsButton() {
        let rail = Rail()
        #expect(rail.downloadsButton.accessibilityLabel() == "Downloads")
        var pressed = false
        rail.onDownloads = { pressed = true }
        rail.downloadsButton.performClick(nil)
        #expect(pressed)
    }

    @Test func popoverShowsRowsAndOwnsOnChangeWhileOpen() async throws {
        let server = try await server(["/a.bin": .body(Data("a".utf8), headers: ["Content-Type": "application/octet-stream"])])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        tab.webView.startDownload(using: URLRequest(url: server.url("/a.bin"))) { downloads.track($0) }
        #expect(await within { downloads.items.first?.state == .finished })

        let popover = DownloadsPopover(downloads: downloads) { _ in }
        _ = popover.view
        #expect(texts(in: popover.view).contains("a.bin"))
        popover.viewWillAppear()
        #expect(downloads.onChange != nil)
        popover.viewWillDisappear()
        #expect(downloads.onChange == nil)
    }

    func texts(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts(in:))
    }

    func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    @Test func emptyPopoverSaysSo() {
        let popover = DownloadsPopover(downloads: Downloads(directory: FileManager.default.temporaryDirectory)) { _ in }
        _ = popover.view
        #expect(texts(in: popover.view).contains("No downloads yet"))
    }

    @Test func manyRowsScrollInsideAShortPopover() async throws {
        let server = try await server(["/a.bin": .body(Data("a".utf8), headers: ["Content-Type": "application/octet-stream"])])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        for _ in 0..<14 {
            tab.webView.startDownload(using: URLRequest(url: server.url("/a.bin"))) { downloads.track($0) }
        }
        #expect(await within { downloads.items.count == 14 && downloads.items.allSatisfy { $0.state == .finished } })

        let popover = DownloadsPopover(downloads: downloads) { _ in }
        _ = popover.view
        popover.view.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollView(in: popover.view))
        #expect(popover.preferredContentSize.height <= 420)
        #expect(try #require(scroll.documentView).frame.height > popover.preferredContentSize.height)
    }

    @Test func aDownloadWithNoKnownLengthShowsAnIndeterminateBar() async throws {
        let server = try await server(["/u.bin": .stall(sent: Data(count: 10), length: nil)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        tab.webView.startDownload(using: URLRequest(url: server.url("/u.bin"))) { downloads.track($0) }
        #expect(await within { downloads.items.first?.state == .running })
        let popover = DownloadsPopover(downloads: downloads) { _ in }
        _ = popover.view
        func bar(in view: NSView) -> NSProgressIndicator? {
            (view as? NSProgressIndicator) ?? view.subviews.lazy.compactMap(bar(in:)).first
        }
        #expect(try #require(bar(in: popover.view)).isIndeterminate)
    }
}
