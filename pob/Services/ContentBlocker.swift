import ContentBlockerConverter
import Foundation
import WebKit
import os

struct FilterList: Equatable {
    let name: String
    let remote: URL
}

/// One profile's filter lists: converted, compiled, kept up to date and handed to its pages.
final class ContentBlocker {
    // shortcut: one compiled list per filter list, assumes each stays under WebKit's 150,000 rules (EasyList converts to 59,774 and EasyPrivacy to 56,480), split if a refresh is ever refused for discarding rules
    /// These names are the only thing about a list that reaches the file system. Its text never does.
    static let lists = [
        FilterList(name: "easylist", remote: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        FilterList(name: "easyprivacy", remote: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]

    private(set) var ruleLists: [WKContentRuleList] = []

    private struct ListState: Codable {
        var refreshed: Date
        var ruleCount: Int
    }

    private typealias Conversion = (json: String, ruleCount: Int, discarded: Int)

    private enum Refusal: Error { case noStore, notAFilterList, tooFewRules(Int), rulesDiscarded(Int), nothingCompiled }

    private static let refreshInterval: TimeInterval = 7 * 86_400
    /// The app's timer asks every minute, so a dead network or a bad list has to cost less than that.
    private static let retryPause: TimeInterval = 3_600

    private let log = os.Logger(subsystem: "pob", category: "ContentBlocker") // the converter has a `Logger` too
    private let store: WKContentRuleListStore?
    private let bundledDirectory: URL
    private let fetch: (URL) async throws -> String
    private let stateFile: JSONFile<[String: ListState]>
    private var states: [String: ListState] = [:]
    /// The pages that follow the rules. A page on a switched-off site isn't in here, so nothing puts rules back on it.
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var isPrepared = false
    private var isRefreshing = false
    private var retryAfter = Date.distantPast

    init(cacheDirectory: URL, bundledDirectory: URL, fetch: @escaping (URL) async throws -> String) {
        self.bundledDirectory = bundledDirectory
        self.fetch = fetch
        stateFile = JSONFile(url: cacheDirectory.appending(path: "lists.json"))
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            store = WKContentRuleListStore(url: cacheDirectory)
        } catch {
            log.error("No rules, because the rules folder can't be made: \(error, privacy: .public)")
            store = nil
        }
    }

    /// Held weakly. The controller gets the rules now and after every update.
    func attach(_ controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        apply(to: controller)
    }

    /// For a page on a switched-off site: the rules come off and stay off, whatever compiles while it's open.
    func detach(_ controller: WKUserContentController) {
        controllers.remove(controller)
        controller.removeAllContentRuleLists()
    }

    /// Adds the current rules once.
    func apply(to controller: WKUserContentController) {
        ruleLists.forEach(controller.add)
    }

    /// Compiled rules when they're on disk, else the bundled text. Pages load without rules until this finishes, so nothing waits for it.
    func prepare() async {
        states = stateFile.load() ?? [:]
        for list in Self.lists {
            if let compiled = try? await store?.contentRuleList(forIdentifier: list.name) {
                install(compiled)
            } else {
                do {
                    let text = try await Self.read(bundledDirectory.appending(path: "\(list.name).txt"))
                    try await compile(await Self.conversion(of: text), as: list, at: .now)
                } catch {
                    log.error("Skipping \(list.name, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
        isPrepared = true
    }

    /// Cheap when nothing is due, so the app's timer can call it every minute. At most one runs at a time.
    func refreshIfStale(now: Date) async {
        guard isPrepared, !isRefreshing, now >= retryAfter else { return }
        let due = Self.lists.filter { list in
            states[list.name].map { now.timeIntervalSince($0.refreshed) > Self.refreshInterval } ?? true
        }
        guard !due.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for list in due {
            do {
                try await refresh(list, now: now)
            } catch {
                log.error("Keeping the last good \(list.name, privacy: .public): \(error, privacy: .public)")
                retryAfter = now.addingTimeInterval(Self.retryPause)
            }
        }
    }

    private func refresh(_ list: FilterList, now: Date) async throws {
        let text = try await fetch(list.remote)
        guard Self.looksLikeFilterList(text) else { throw Refusal.notAFilterList }
        let conversion = await Self.conversion(of: text)
        // Losing over half its rules means a broken download, not a quiet week.
        guard conversion.ruleCount * 2 >= states[list.name]?.ruleCount ?? 0 else { throw Refusal.tooFewRules(conversion.ruleCount) }
        // The converter cuts from the end, which is where the exceptions are, so a page would break.
        guard conversion.discarded == 0 else { throw Refusal.rulesDiscarded(conversion.discarded) }
        try await compile(conversion, as: list, at: now)
    }

    private func compile(_ conversion: Conversion, as list: FilterList, at date: Date) async throws {
        guard let store else { throw Refusal.noStore }
        let compiled = try await store.compileContentRuleList(forIdentifier: list.name, encodedContentRuleList: conversion.json)
        guard let compiled else { throw Refusal.nothingCompiled }
        install(compiled)
        states[list.name] = ListState(refreshed: date, ruleCount: conversion.ruleCount)
        do { try stateFile.save(states) } catch {
            log.error("Saving the refresh dates failed: \(error, privacy: .public)")
        }
    }

    /// WebKit keeps one list per identifier, so adding a new one replaces the old.
    private func install(_ list: WKContentRuleList) {
        ruleLists.removeAll { $0.identifier == list.identifier }
        ruleLists.append(list)
        controllers.allObjects.forEach { $0.add(list) }
    }

    /// A captive portal or an error page answers 200 too, and a filter list always opens with this header.
    private static func looksLikeFilterList(_ text: String) -> Bool {
        text.hasPrefix("[Adblock")
    }

    /// WebKit JSON. Too slow for the main actor on a real list, so the app goes through `conversion(of:)`.
    nonisolated static func convert(_ text: String) -> String {
        converted(text).safariRulesJSON
    }

    private nonisolated static func converted(_ text: String) -> ConversionResult {
        ContentBlockerConverter().convertArray(
            rules: text.split(whereSeparator: \.isNewline).map(String.init),
            safariVersion: .autodetect(),
            advancedBlocking: false
        )
    }

    @concurrent private nonisolated static func conversion(of text: String) async -> Conversion {
        let result = converted(text)
        return (result.safariRulesJSON, result.safariRulesCount, result.discardedSafariRules)
    }

    @concurrent private nonisolated static func read(_ file: URL) async throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    nonisolated static func downloadConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return configuration
    }

    /// The real `fetch`. The lists are about 2 MB each.
    nonisolated static func download(_ url: URL) async throws -> String {
        try await download(url, configuration: downloadConfiguration(), limit: 16 << 20)
    }

    /// The limit holds while the bytes arrive, so an endless answer ends here and not on the disk.
    @concurrent nonisolated static func download(_ url: URL, configuration: sending URLSessionConfiguration, limit: Int) async throws -> String {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return text
    }
}
