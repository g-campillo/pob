import Foundation
import WebKit

/// One window's tabs: the records that outlast a web view, and the live `Tab`s behind them.
final class TabManager {
    let profile: Profile
    private(set) var list = TabList()
    var onChange: (() -> Void)?
    var onActiveChange: (() -> Void)?
    var onLoadFinished: ((Tab) -> Void)?
    /// Replaceable because tests can't start a real capture.
    var isCapturing: (Tab) -> Bool = { $0.isCapturing }

    private let keepsSpare: Bool
    private var tabs: [UUID: Tab] = [:]
    private var phases: [UUID: TabPhase] = [:]
    private var lastActive: [UUID: Date] = [:]
    private var openers: [UUID: UUID] = [:]

    init(profile: Profile, keepsSpare: Bool = true) {
        self.profile = profile
        self.keepsSpare = keepsSpare
    }

    var isEmpty: Bool { list.records.isEmpty }
    var activeTab: Tab? { list.activeID.flatMap(liveTab) }

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
        changeList { $0.close(id) }
    }

    func reopenLast() { changeList { _ = $0.reopenLast() } }
    func activate(_ id: UUID) { changeList { $0.activate(id) } }
    func activate(index: Int) { changeList { $0.activate(index: index) } }
    func activateNext() { changeList { $0.activateNext() } }
    func activatePrevious() { changeList { $0.activatePrevious() } }
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
        }
        tab.onLoadFinished = { [weak self, weak tab] in
            if let tab {
                self?.onLoadFinished?(tab)
            }
        }
        tab.onOpenLink = { [weak self] request, activate in
            self?.newTab(nil, activate: activate).webView.load(request)
        }
        tab.onCreatePopup = { [weak self] configuration in
            guard let self else { return nil }
            let popup = Tab(profile: profile, configuration: configuration)
            add(popup, activate: true, opener: id)
            return popup.webView
        }
        tab.onCloseRequested = { [weak self] in self?.closeFromPage(id) }
    }

    /// A finished sign-in reads as a bug if it lands on an unrelated tab, so an active popup hands back to its opener.
    private func closeFromPage(_ id: UUID) {
        if id == list.activeID, let opener = openers[id] {
            activate(opener)
        }
        close(id)
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
    }

    /// Keeps the page's place in its record and lets go of the web view.
    private func release(_ id: UUID) {
        guard let tab = tabs.removeValue(forKey: id) else { return }
        list.update(id) { record in
            record.url = tab.webView.url ?? record.url
            record.title = tab.webView.title ?? record.title
            record.interactionState = tab.webView.interactionState as? Data
        }
        tab.pageView.removeFromSuperview()
        phases[id] = nil
        lastActive[id] = nil
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
