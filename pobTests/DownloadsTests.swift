import Foundation
import Network
import Testing
import WebKit
@testable import pob

/// A loopback HTTP server, so downloads run through real WebKit without the internet.
final class LocalServer {
    enum Reply {
        case body(Data, headers: [String: String] = [:])
        /// Promises `length` bytes, sends `sent`, then stays silent until `dropConnections()`.
        case stall(sent: Data, length: Int)
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
        connections.forEach { $0.cancel() }
        connections = []
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
                connection.cancel()
            })
        case .stall(let sent, let length)?:
            head += "Content-Type: application/octet-stream\r\nContent-Length: \(length)\r\n\r\n"
            connection.send(content: Data(head.utf8) + sent, completion: .idempotent)
        case nil:
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

@Suite struct DownloadsTests {
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
    @Test(arguments: ["../../.zshrc", "/etc/passwd", "a/b/c.txt", "..\\..\\x.txt"])
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
        let buttons = popover.view.subviews.first.map { ($0 as? NSStackView)?.arrangedSubviews ?? [] } ?? []
        #expect(buttons.count == 1)
        popover.viewWillAppear()
        #expect(downloads.onChange != nil)
        popover.viewWillDisappear()
        #expect(downloads.onChange == nil)
    }
}
