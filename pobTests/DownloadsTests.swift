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
        /// Closes the connection with no response.
        case hangUp
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
        case .hangUp?:
            close(connection)
        case nil:
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in
                MainActor.assumeIsolated { self.close(connection) }
            })
        }
    }
}

/// Never on screen: tests that need a real sheet put it on a window far outside every display.
@MainActor func offscreenWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    return window
}

private let stubWindow = NSWindow()

/// The old tests aren't about the question, so they answer Download.
func allowDownloads(_ downloads: Downloads) {
    downloads.frontWindow = { stubWindow }
    downloads.alertSeam = { _ in .alertFirstButtonReturn }
}

/// What the question showed, and what it was answered.
final class Asked {
    var alerts: [NSAlert] = []
    var answer: NSApplication.ModalResponse = .alertFirstButtonReturn
    func install(on downloads: Downloads) {
        downloads.frontWindow = { stubWindow }
        downloads.alertSeam = { [self] alert in
            alerts.append(alert)
            return answer
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
    @Test func lineSeparatorsAreStrippedSoANameCantAddALineToTheSheet() throws {
        let folder = try directory()
        let name = Downloads.safeDestination(directory: folder, suggestedFilename: "a.zip\u{2028}From apple.com\u{2029}x").lastPathComponent
        #expect(name == "a.zipFrom apple.comx")
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
        allowDownloads(downloads)
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
        allowDownloads(downloads)

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
        allowDownloads(downloads)
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
        allowDownloads(downloads)
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
        allowDownloads(downloads)
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
        allowDownloads(downloads)
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
        allowDownloads(downloads)
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
        allowDownloads(downloads)
        tab.webView.startDownload(using: URLRequest(url: server.url("/half.bin"))) { downloads.track($0) }
        #expect(await within { abs((downloads.items.first?.progress ?? 0) - 0.5) < 0.01 })
    }

    @Test func attachmentFromAPopupClosesThePopupAndReturnsToTheOpener() async throws {
        let server = try await server(["/a.bin": .body(Data("a".utf8), headers: ["Content-Disposition": "attachment; filename=a.bin"])])
        defer { server.stop() }
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let opener = tabs.newTab(nil, activate: true)
        allowDownloads(opener.profile.downloads)
        let popup = try #require(opener.onCreatePopup?(opener.webView.configuration))
        #expect(tabs.activeTab?.webView === popup)

        popup.load(URLRequest(url: server.url("/a.bin")))

        #expect(await within { opener.profile.downloads.items.first?.state == .finished })
        #expect(await within { tabs.activeTab === opener })
        #expect(tabs.list.records.count == 1)
    }

    // MARK: Asking first

    static let binary = ["Content-Type": "application/octet-stream"]

    @Test func theSheetNamesTheCleanedFileAndTheHost() async throws {
        let long = String(repeating: "a", count: 150)
        let server = try await server([
            "/hostile": .body(Data("x".utf8), headers: ["Content-Disposition": "attachment; filename*=UTF-8''report%E2%80%AEfdp.app"]),
            "/\(long).pdf": .body(Data("x".utf8), headers: Self.binary),
        ])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let asked = Asked()
        asked.install(on: tab.profile.downloads)

        tab.webView.load(URLRequest(url: server.url("/hostile")))
        #expect(await within { asked.alerts.count == 1 })
        let hostile = try #require(asked.alerts.first)
        #expect(hostile.messageText == "Download \"reportfdp.app\"?")
        #expect(hostile.informativeText == "From 127.0.0.1")
        #expect(hostile.buttons.map(\.title) == ["Download", "Cancel"])
        #expect(hostile.buttons.first?.keyEquivalent == "\r")

        tab.webView.startDownload(using: URLRequest(url: server.url("/\(long).pdf"))) { tab.profile.downloads.track($0) }
        #expect(await within { asked.alerts.count == 2 })
        let name = try #require(asked.alerts.last?.messageText.split(separator: "\"").dropFirst().first)
        #expect(name.count <= 81 && name.hasSuffix(".pdf") && name.contains("…"))
    }

    @Test func answeringDownloadContinuesWithARowANoticeAndTheBytes() async throws {
        let server = try await server(["/file.bin": .body(Data("real bytes".utf8), headers: Self.binary)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        let asked = Asked()
        asked.install(on: downloads)
        var notices: [String] = []
        downloads.onStart = { notices.append($0) }

        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }

        #expect(await within { downloads.items.first?.state == .finished })
        #expect(asked.alerts.count == 1)
        #expect(notices == ["file.bin"])
        #expect(try String(contentsOf: try #require(downloads.items.first).destination, encoding: .utf8) == "real bytes")
    }

    @Test func cancelLeavesNoFileRowNoticeOrClaimedName() async throws {
        let server = try await server(["/file.bin": .body(Data("x".utf8), headers: Self.binary)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        let asked = Asked()
        asked.answer = .alertSecondButtonReturn
        asked.install(on: downloads)
        var notices: [String] = []
        downloads.onStart = { notices.append($0) }

        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }
        #expect(await within { asked.alerts.count == 1 })
        try await Task.sleep(for: .milliseconds(400)) // the failure WebKit reports afterward must add nothing

        #expect(downloads.items.isEmpty)
        #expect(notices.isEmpty)
        #expect(downloads.destination(for: "file.bin").lastPathComponent == "file.bin")
        #expect(!FileManager.default.fileExists(atPath: tab.profile.directory.appending(path: "Downloads/file.bin").path))
    }

    @Test func noWindowAtAllShowsNothingAndAddsNoRow() async throws {
        let server = try await server(["/file.bin": .body(Data("x".utf8), headers: Self.binary)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        var shown = 0
        downloads.alertSeam = { _ in shown += 1; return .alertFirstButtonReturn }
        downloads.frontWindow = { nil }
        var notices: [String] = []
        downloads.onStart = { notices.append($0) }

        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }
        try await Task.sleep(for: .milliseconds(800))

        #expect(shown == 0)
        #expect(downloads.items.isEmpty)
        #expect(notices.isEmpty)
    }

    @Test func aBackgroundTabsDownloadAsksOnTheFrontWindow() async throws {
        let server = try await server(["/file.bin": .body(Data("x".utf8), headers: Self.binary)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        #expect(tab.webView.window == nil)
        let downloads = tab.profile.downloads
        let asked = Asked()
        asked.install(on: downloads)
        var consulted = 0
        let front = downloads.frontWindow
        downloads.frontWindow = { consulted += 1; return front?() }

        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }

        #expect(await within { downloads.items.first?.state == .finished })
        #expect(consulted == 1)
        #expect(asked.alerts.count == 1)
    }

    @Test func retryDoesntAskAgain() async throws {
        let server = try await server(["/f.bin": .stall(sent: Data("part".utf8), length: 1_000_000)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        let asked = Asked()
        asked.install(on: downloads)
        tab.webView.startDownload(using: URLRequest(url: server.url("/f.bin"))) { downloads.track($0) }
        #expect(await within { downloads.items.first?.state == .running })
        server.dropConnections()
        #expect(await within { downloads.items.first?.state == .failed })
        server.routes["/f.bin"] = .body(Data("whole".utf8), headers: Self.binary)

        downloads.retry(try #require(downloads.items.first).id, in: tab.webView)

        #expect(await within { downloads.items.contains { $0.state == .finished } })
        #expect(asked.alerts.count == 1)
    }

    @Test func aSecondDownloadFromThePageWhileItsSheetIsUpIsDroppedAndTheFirstStillWorks() async throws {
        let server = try await server(["/a.bin": .body(Data("a".utf8), headers: Self.binary), "/b.bin": .body(Data("b".utf8), headers: Self.binary)])
        defer { server.stop() }
        let window = offscreenWindow()
        defer { window.close() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        downloads.frontWindow = { window }
        tab.webView.startDownload(using: URLRequest(url: server.url("/a.bin"))) { downloads.track($0) }
        #expect(await within { window.attachedSheet != nil })

        tab.webView.startDownload(using: URLRequest(url: server.url("/b.bin"))) { downloads.track($0) }
        try await Task.sleep(for: .milliseconds(800))
        #expect(window.sheets.count == 1) // nothing stacked behind the first
        #expect(downloads.items.isEmpty)

        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        #expect(await within { downloads.items.first?.state == .finished })
        #expect(downloads.items.map(\.filename) == ["a.bin"])
    }

    @Test func afterCancelThePagesDownloadsAreDroppedFor3SecondsAndOtherPagesAreNotAffected() async throws {
        let server = try await server(["/file.bin": .body(Data("x".utf8), headers: Self.binary)])
        defer { server.stop() }
        let profile = Profile.temporary()
        let tab = Tab(profile: profile), other = Tab(profile: profile)
        let downloads = profile.downloads
        let asked = Asked()
        asked.answer = .alertSecondButtonReturn
        asked.install(on: downloads)
        var clock = Date(timeIntervalSince1970: 1_000)
        downloads.now = { clock }
        func request(_ tab: Tab) { tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) } }

        request(tab)
        #expect(await within { asked.alerts.count == 1 })

        clock += 2.9
        request(tab)
        try await Task.sleep(for: .milliseconds(800))
        #expect(asked.alerts.count == 1) // dropped without asking

        request(other)
        #expect(await within { asked.alerts.count == 2 }) // another page still asks

        clock += 0.2
        request(tab)
        #expect(await within { asked.alerts.count == 3 }) // past the pause, it asks again
        #expect(downloads.items.isEmpty)
    }

    @Test func aWindowWithNoAnswerGivenDoesntStartThePause() async throws {
        let server = try await server(["/file.bin": .body(Data("x".utf8), headers: Self.binary)])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        let asked = Asked()
        asked.answer = .cancel // what a window that can't show it answers
        asked.install(on: downloads)

        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }
        #expect(await within { asked.alerts.count == 1 })
        try await Task.sleep(for: .milliseconds(400))
        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }

        #expect(await within { asked.alerts.count == 2 })
    }

    @Test func closingTheWindowUnderTheSheetAnswersCancelSoNothingHangs() async throws {
        let server = try await server(["/file.bin": .body(Data("x".utf8), headers: Self.binary)])
        defer { server.stop() }
        let window = offscreenWindow()
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        downloads.frontWindow = { window }
        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }
        #expect(await within { window.attachedSheet != nil })

        window.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(downloads.items.isEmpty)

        // The page's pending question was settled, so its next download asks on a new window.
        let next = offscreenWindow()
        defer { next.close() }
        downloads.frontWindow = { next }
        tab.webView.startDownload(using: URLRequest(url: server.url("/file.bin"))) { downloads.track($0) }
        #expect(await within { next.attachedSheet != nil })
        next.endSheet(try #require(next.attachedSheet), returnCode: .alertSecondButtonReturn)
    }

    @Test func aWindowAlreadyShowingASheetQueuesTheSecondOneAndBothAnswerOnce() async throws {
        let server = try await server(["/a.bin": .body(Data("a".utf8), headers: Self.binary), "/b.bin": .body(Data("b".utf8), headers: Self.binary)])
        defer { server.stop() }
        let window = offscreenWindow()
        defer { window.close() }
        let profile = Profile.temporary()
        let first = Tab(profile: profile), second = Tab(profile: profile) // two pages, so neither drops the other
        let downloads = profile.downloads
        downloads.frontWindow = { window }
        first.webView.startDownload(using: URLRequest(url: server.url("/a.bin"))) { downloads.track($0) }
        #expect(await within { window.attachedSheet != nil })
        second.webView.startDownload(using: URLRequest(url: server.url("/b.bin"))) { downloads.track($0) }
        #expect(await within { window.sheets.count == 2 })

        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        #expect(await within { downloads.items.count == 1 && downloads.items[0].state == .finished })
        #expect(await within { window.sheets.count == 1 && window.attachedSheet != nil })
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        #expect(await within { downloads.items.count == 2 && downloads.items.allSatisfy { $0.state == .finished } })
        #expect(Set(downloads.items.map(\.filename)) == ["a.bin", "b.bin"])
    }

    @Test func attachmentAndTargetBlankAttachmentAndDownloadLinkAllAsk() async throws {
        let page = #"""
        <a id="d" href="/data.bin" download="chosen.bin">d</a>
        <a id="b" href="/att" target="_blank">b</a>
        """#
        let server = try await server([
            "/": .body(Data(page.utf8), headers: ["Content-Type": "text/html"]),
            "/data.bin": .body(Data("x".utf8), headers: Self.binary),
            "/att": .body(Data("hello".utf8), headers: ["Content-Type": "text/plain", "Content-Disposition": "attachment; filename=\"att.txt\""]),
        ])
        defer { server.stop() }
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let downloads = tab.profile.downloads
        let asked = Asked()
        asked.answer = .alertSecondButtonReturn
        asked.install(on: downloads)
        var clock = Date(timeIntervalSince1970: 1_000)
        downloads.now = { clock }
        await finishLoading(tab) { tab.webView.load(URLRequest(url: server.url("/"))) }

        _ = try await tab.webView.evaluateJavaScript("document.getElementById('d').click()")
        #expect(await within { asked.alerts.count == 1 })
        #expect(asked.alerts.first?.messageText == "Download \"chosen.bin\"?")

        clock += 4
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('b').click()")
        #expect(await within { asked.alerts.count == 2 })
        #expect(asked.alerts.last?.messageText == "Download \"att.txt\"?")

        clock += 4
        tab.webView.load(URLRequest(url: server.url("/att")))
        #expect(await within { asked.alerts.count == 3 })
        #expect(downloads.items.isEmpty)
    }

    @Test func aRowMadeWithoutAQuestionStillAsksOnRetry() async throws {
        let server = try await server(["/hang.bin": .hangUp])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let downloads = tab.profile.downloads
        let asked = Asked()
        asked.install(on: downloads)
        tab.webView.startDownload(using: URLRequest(url: server.url("/hang.bin"))) { downloads.track($0) }
        #expect(await within { downloads.items.first?.state == .failed }) // the row stays, and it was never asked about
        #expect(asked.alerts.isEmpty)
        server.routes["/hang.bin"] = .body(Data("whole".utf8), headers: Self.binary)

        downloads.retry(try #require(downloads.items.first).id, in: tab.webView)

        #expect(await within { downloads.items.contains { $0.state == .finished } })
        #expect(asked.alerts.count == 1)
    }

    @Test func aScriptStartedDownloadWithNoClickAsks() async throws {
        let page = #"<body><script>var a=document.createElement('a');a.href='/data.bin';a.download='x.bin';document.body.appendChild(a);a.click();</script></body>"#
        let server = try await server([
            "/": .body(Data(page.utf8), headers: ["Content-Type": "text/html"]),
            "/data.bin": .body(Data("x".utf8), headers: Self.binary),
        ])
        defer { server.stop() }
        let tab = Tab(profile: .temporary())
        let asked = Asked()
        asked.answer = .alertSecondButtonReturn
        asked.install(on: tab.profile.downloads)

        tab.webView.load(URLRequest(url: server.url("/")))

        #expect(await within { asked.alerts.count == 1 })
        #expect(asked.alerts.first?.messageText == "Download \"x.bin\"?")
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
        allowDownloads(downloads)
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
        allowDownloads(downloads)
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
        allowDownloads(downloads)
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
