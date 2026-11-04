import Foundation

struct SwitcherRow: Equatable {
    enum Target: Equatable { case tab(UUID), url(URL), command(CommandID), address(AddressInput) }
    let target: Target
    let title: String
    let subtitle: String
    let section: String    // "Tabs", "Bookmarks", "History", "Commands" or ""
}

/// The one search behind the switcher and the address field.
enum SwitcherModel {
    private static let tabLimit = 5
    private static let bookmarkLimit = 3
    private static let historyLimit = 5
    private static let commandLimit = 3

    /// Pages already listed drop out of History, so the store is asked for enough to fill the section anyway.
    static let historySearchLimit = tabLimit + bookmarkLimit + historyLimit

    static func rows(query: String, tabs: [TabRecord], bookmarks: [Bookmark], history: [HistoryEntry], commands: [Command]) -> [SwitcherRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ candidate: String) -> Bool { candidate.localizedCaseInsensitiveContains(text) }

        let shownTabs = (text.isEmpty ? tabs : tabs.filter {
            matches(TabListView.displayTitle(for: $0)) || matches($0.url?.absoluteString ?? "")
        }).prefix(tabLimit)
        var rows = shownTabs.map {
            SwitcherRow(target: .tab($0.id), title: TabListView.displayTitle(for: $0), subtitle: $0.url?.absoluteString ?? "", section: "Tabs")
        }
        guard let input = AddressInput.classify(text) else { return rows }

        // Each page shows once, in the first section that has it: Return should find an open tab before opening it again.
        var listed = Set(shownTabs.compactMap(\.url))
        if case .url(let url) = input, listed.insert(url).inserted {
            rows.append(SwitcherRow(target: .address(input), title: url.absoluteString, subtitle: "Open Address", section: ""))
        }
        let shownBookmarks = bookmarks.filter {
            !listed.contains($0.url) && (matches($0.title) || matches($0.url.absoluteString))
        }.prefix(bookmarkLimit)
        listed.formUnion(shownBookmarks.map(\.url))

        rows += shownBookmarks.map {
            SwitcherRow(target: .url($0.url), title: $0.title, subtitle: $0.url.absoluteString, section: "Bookmarks")
        }
        rows += history.filter { !listed.contains($0.url) }.prefix(historyLimit).map {
            SwitcherRow(target: .url($0.url), title: $0.title.isEmpty ? $0.url.absoluteString : $0.title, subtitle: $0.url.absoluteString, section: "History")
        }
        rows += commands.filter { matches($0.title) }.prefix(commandLimit).map {
            SwitcherRow(target: .command($0.id), title: $0.title, subtitle: "", section: "Commands")
        }
        if case .search = input {
            rows.append(SwitcherRow(target: .address(input), title: text, subtitle: "Search Google", section: ""))
        }
        return rows
    }

    /// What's left of the last answer once the text has changed, for the moment before history answers again.
    static func stillMatching(_ history: [HistoryEntry], query: String) -> [HistoryEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return history.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.url.absoluteString.localizedCaseInsensitiveContains(text)
        }
    }
}
