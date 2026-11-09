import Foundation
import WebKit

/// One window's tabs: the records that outlast a web view, and the live `Tab`s behind them.
final class TabManager {
    let profile: Profile
    private(set) var list = TabList()
    var onChange: (() -> Void)?
    var onActiveChange: (() -> Void)?
    var onLoadFinished: ((Tab) -> Void)?
    /// Only the active tab's loading, so a background page never shows.
    var onActiveProgress: ((Double, Bool) -> Void)?
    /// Replaceable so tests can see whether a page asked for its icon.
    var updateFavicon: (FaviconStore, String, WKWebView) async -> Void = { await $0.update(host: $1, from: $2) }
    /// Replaceable because tests can't start a real capture.
    var isCapturing: (Tab) -> Bool = { $0.isCapturing }

    private let keepsSpare: Bool
    private var tabs: [UUID: Tab] = [:]
    private var phases: [UUID: TabPhase] = [:]
    private var lastActive: [UUID: Date] = [:]
    private var openers: [UUID: UUID] = [:]
    /// Tabs a ⌘-click opened, which close again if the link turns out to be a download. Not openers, so ⌘W doesn't change.
    private var linkOpened: Set<UUID> = []
    /// The address each rebuilt tab is bringing back. That load isn't a visit, and the entry goes at the first finish, whatever it was.
    private var restored: [UUID: URL] = [:]
    private var recordedTitles: [UUID: String] = [:]

    /// Restored tabs start saved, except the active one, so a launch builds one web view per window.
    init(profile: Profile, keepsSpare: Bool = true, restoring snapshot: WindowSnapshot? = nil) {
        self.profile = profile
        self.keepsSpare = keepsSpare
        if let snapshot {
            changeList { $0 = TabList(records: snapshot.tabs, activeID: snapshot.activeID) }
        }
    }

    var isEmpty: Bool { list.records.isEmpty }
    var activeTab: Tab? { list.activeID.flatMap(liveTab) }
    var isCapturingAny: Bool { tabs.values.contains(where: isCapturing) }

    /// The records with each live page's place read now, which isn't free, so it's for saving and not for every change.
    var snapshotRecords: [TabRecord] {
        list.records.map { record in
            var record = record
            if let tab = tabs[record.id] {
                capture(tab, in: &record)
            }
            return record
        }
    }

    func phase(of id: UUID) -> TabPhase { phases[id] ?? .saved }
    func liveTab(_ id: UUID) -> Tab? { tabs[id] }

    @discardableResult
    func newTab(_ input: AddressInput?, activate: Bool) -> Tab {
        let tab = profile.takeSpareTab()
        if keepsSpare {
            Task { [profile] in profile.prepareSpareTab() }
        }
        if let input {
            tab.load(input)
        }
        add(tab, activate: activate)
        return tab
    }

    func close(_ id: UUID) {
        release(id)
        openers[id] = nil
        linkOpened.remove(id)
        changeList { $0.close(id) }
    }

    func reopenLast() { changeList { _ = $0.reopenLast() } }
    func activate(_ id: UUID) { switchTab { $0.activate(id) } }
    func activate(index: Int) { switchTab { $0.activate(index: index) } }
    func activateNext() { switchTab { $0.activateNext() } }
    func activatePrevious() { switchTab { $0.activatePrevious() } }
    func move(from: Int, to: Int) { changeList { $0.move(from: from, to: to) } }

    func updatePhases(now: Date, memoryPressure: Bool) {
        for (id, tab) in tabs {
            let next = TabLifecycle.nextPhase(
                current: phase(of: id),
                isActive: id == list.activeID,
                isCapturing: isCapturing(tab),
                idleSeconds: now.timeIntervalSince(lastActive[id] ?? now),
                memoryPressure: memoryPressure
            )
            if next == .saved {
                release(id)
            } else {
                setPhase(next, of: id)
            }
        }
    }

    private func add(_ tab: Tab, activate: Bool, opener: UUID? = nil) {
        let record = TabRecord(url: tab.webView.url)
        openers[record.id] = opener
        // A page opened in the background would otherwise run its load-time code at zero width.
        tab.pageView.frame = activeTab?.pageView.frame ?? tab.pageView.frame
        adopt(tab, as: record.id)
        changeList { $0.add(record, activate: activate) }
    }

    private func adopt(_ tab: Tab, as id: UUID) {
        tabs[id] = tab
        lastActive[id] = .now
        setPhase(.background, of: id)

        tab.onStateChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            list.update(id) { record in
                record.url = tab.webView.url ?? record.url
                record.title = tab.title.isEmpty ? record.title : tab.title
            }
            onChange?()
            if !tab.isShowingErrorPage, let url = tab.webView.url, isRecordable(url), !tab.title.isEmpty, recordedTitles[id] != tab.title {
                recordedTitles[id] = tab.title
                Task { [history = profile.history, title = tab.title] in await history.updateTitle(url: url, title: title) }
            }
        }
        tab.onLoadFinished = { [weak self, weak tab] in
            if let tab {
                let restoring = self?.restored.removeValue(forKey: id)
                self?.list.update(id) { $0.interactionState = nil } // the page is back, so its own state counts from here
                if !tab.isShowingErrorPage { // a typo would otherwise become a suggestion
                    if restoring == nil || restoring != tab.webView.url { self?.recordVisit(of: tab) }
                    self?.refreshFavicon(of: tab)
                }
                self?.onLoadFinished?(tab)
            }
        }
        tab.onProgress = { [weak self] progress, isLoading in
            guard let self, id == list.activeID else { return }
            onActiveProgress?(progress, isLoading)
        }
        tab.onOpenLink = { [weak self] request, activate in
            guard let self else { return }
            let opened = newTab(nil, activate: activate)
            if let key = tabs.first(where: { $0.value === opened })?.key { linkOpened.insert(key) }
            opened.webView.load(request)
        }
        tab.onCreatePopup = { [weak self] configuration in
            guard let self else { return nil }
            configuration.userContentController = WKUserContentController() // WebKit passes the opener's, and each tab switches its own rules
            let popup = Tab(profile: profile, configuration: configuration)
            add(popup, activate: true, opener: id)
            return popup.webView
        }
        tab.onCloseRequested = { [weak self] in self?.closeFromPage(id) }
        tab.onBecameDownload = { [weak self, weak tab] in
            // A `target="_blank"` attachment opens a tab that never gets a page, so it goes back to where it came from.
            // `url` already holds the address being loaded, so the committed page is what says whether it has one.
            let committed = tab?.webView.backForwardList.currentItem?.url
            guard let self, (openers[id] != nil || linkOpened.contains(id)), committed == nil || committed?.scheme == "about" else { return }
            closeFromPage(id)
        }
    }

    /// A private window leaves no history and no icons, so nothing it shows is recorded.
    private func isRecordable(_ url: URL) -> Bool { !profile.isPrivate && (url.scheme == "http" || url.scheme == "https") }

    private func recordVisit(of tab: Tab) {
        guard let url = tab.webView.url, isRecordable(url) else { return }
        Task { [history = profile.history, title = tab.title] in await history.record(url: url, title: title) }
    }

    private func refreshFavicon(of tab: Tab) {
        guard let url = tab.webView.url, isRecordable(url), let host = url.host() else { return }
        Task { [weak self, weak tab] in
            guard let self, let webView = tab?.webView else { return }
            await updateFavicon(profile.favicons, host, webView)
            onChange?()
        }
    }

    /// A finished sign-in reads as a bug if it lands on an unrelated tab, so an active popup hands back to its opener.
    private func closeFromPage(_ id: UUID) {
        if id == list.activeID, let opener = openers[id] {
            activate(opener)
        }
        close(id)
    }

    /// Timed to the window showing the page, through `onActiveChange`, and not to the page's load.
    private func switchTab(_ change: (inout TabList) -> Void) {
        Speed.signposter.withIntervalSignpost("Tab switch") { changeList(change) }
    }

    /// Every change to the list comes through here, so the live tabs and the window follow it.
    private func changeList(_ change: (inout TabList) -> Void) {
        let previous = list.activeID
        change(&list)
        if list.activeID != previous {
            if let previous, tabs[previous] != nil {
                lastActive[previous] = .now
                setPhase(.background, of: previous)
            }
            if let active = list.active {
                rebuild(active)
                setPhase(.active, of: active.id)
            }
            onActiveChange?()
            // A certificate question that a window-less tab couldn't ask comes back now that the tab has a window.
            if let retry = activeTab?.retryURL {
                activeTab?.retryURL = nil
                activeTab?.load(.url(retry))
            }
        }
        onChange?()
    }

    /// Brings back a tab that gave up its web view, at the place it left off.
    private func rebuild(_ record: TabRecord) {
        guard tabs[record.id] == nil else { return }
        let tab = Tab(profile: profile)
        adopt(tab, as: record.id)
        if let state = record.interactionState {
            tab.webView.interactionState = state
        }
        // A page with no history entry, like a failed load, restores to nothing, but the record still knows the address.
        if tab.webView.url == nil, let url = record.url {
            tab.load(.url(url))
        }
        restored[record.id] = tab.webView.url
    }

    /// Keeps the page's place in its record and lets go of the web view.
    private func release(_ id: UUID) {
        guard let tab = tabs.removeValue(forKey: id) else { return }
        list.update(id) { capture(tab, in: &$0) }
        tab.pageView.removeFromSuperview()
        phases[id] = nil
        lastActive[id] = nil
        recordedTitles[id] = nil
        restored[id] = nil
    }

    /// A page on its way back keeps what it had. It has no title yet, and WebKit's state for a page in mid-load
    /// restores as a fresh load of it, which loses the forward list.
    private func capture(_ tab: Tab, in record: inout TabRecord) {
        record.url = tab.webView.url ?? record.url
        record.title = tab.title.isEmpty ? record.title : tab.title
        if record.interactionState == nil || !tab.webView.isLoading {
            record.interactionState = tab.webView.interactionState as? Data ?? record.interactionState
        }
    }

    private func setPhase(_ phase: TabPhase, of id: UUID) {
        guard let tab = tabs[id] else { return }
        phases[id] = phase
        if phase != .active, !isCapturing(tab) {
            tab.pageView.removeFromSuperview()
        }
        applySchedulingPolicy(of: tab)
    }

    /// A popup shares its opener's preferences, and so their policy. The one that needs the most running time sets it.
    private func applySchedulingPolicy(of tab: Tab) {
        let preferences = tab.webView.configuration.preferences
        let sharing = tabs.filter { $0.value.webView.configuration.preferences === preferences }
        preferences.inactiveSchedulingPolicy =
            if sharing.values.contains(where: isCapturing) {
                .none
            } else if sharing.keys.allSatisfy({ phase(of: $0) == .suspended }) {
                .suspend
            } else {
                .throttle
            }
    }
}
