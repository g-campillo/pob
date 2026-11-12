import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct SwitcherModelTests {
    let deployTab = TabRecord(url: URL(string: "https://docs.example.com/deploy"), title: "Deploy guide")
    let bookmark = Bookmark(id: UUID(), title: "Deployment checklist", url: URL(string: "https://example.com/check")!, folder: nil)
    let visit = HistoryEntry(url: URL(string: "https://ops.example.com/deploy")!, title: "Deploy logs", visitCount: 2, lastVisit: .now)
    let commands = CommandList.standard { _ in }.all

    func rows(_ query: String) -> [SwitcherRow] {
        SwitcherModel.rows(query: query, tabs: [deployTab], bookmarks: [bookmark], history: [visit], commands: commands)
    }

    @Test func openTabsComeFirstThenBookmarksThenHistory() {
        #expect(Array(rows("dep").map(\.section).prefix(3)) == ["Tabs", "Bookmarks", "History"])
    }
    @Test func theFirstRowIsWhatReturnChooses() {
        #expect(rows("dep").first?.target == .tab(deployTab.id))
    }
    @Test func aFullAddressWithNoOpenTabGoesThere() {
        #expect(rows("apple.com").first?.target == .address(.url(URL(string: "https://apple.com")!)))
    }
    @Test func unmatchedTextEndsInASearchRow() {
        let result = SwitcherModel.rows(query: "zzzz nothing", tabs: [deployTab], bookmarks: [bookmark], history: [], commands: commands)
        #expect(result.count == 1)
        guard case .address(.search) = result[0].target else {
            Issue.record("expected a search row")
            return
        }
    }
    @Test func commandsMatchByTitle() {
        #expect(rows("web insp").contains { $0.target == .command(.toggleInspector) })
    }
    /// A wrong search is harmless, and a wrong command acts on the page, so Return on a plain word has to search.
    @Test(arguments: ["zoom", "back", "print", "close", "bookmark"])
    func aWordFromACommandTitleStillSearchesFirst(word: String) {
        let result = SwitcherModel.rows(query: word, tabs: [], bookmarks: [], history: [], commands: commands)
        guard case .address(.search) = result.first?.target else {
            Issue.record("expected the search row first")
            return
        }
        #expect(result.dropFirst().allSatisfy { $0.section == "Commands" })
        #expect(result.count > 1)
    }
    @Test func emptyQueriesListOpenTabs() {
        #expect(rows("").map(\.target) == [.tab(deployTab.id)])
    }
    @Test func aHistoryPageThatsAlsoBookmarkedShowsOnce() {
        let page = URL(string: "https://example.com/check")!
        let entry = HistoryEntry(url: page, title: "Deployment checklist", visitCount: 1, lastVisit: .now)
        let result = SwitcherModel.rows(query: "dep", tabs: [], bookmarks: [bookmark], history: [entry], commands: [])
        #expect(result.filter { $0.target == .url(page) }.count == 1)
    }
}

@Suite struct SwitcherLimitTests {
    let commands = CommandList.standard { _ in }.all

    func page(_ index: Int) -> URL { URL(string: "https://example.com/deploy/\(index)")! }
    func bookmark(_ url: URL) -> Bookmark { Bookmark(id: UUID(), title: "Deploy", url: url, folder: nil) }
    func visit(_ url: URL) -> HistoryEntry { HistoryEntry(url: url, title: "Deploy", visitCount: 1, lastVisit: .now) }

    @Test func eachSectionStopsAtItsLimit() {
        let tabs = (0..<9).map { TabRecord(url: page($0), title: "Deploy") }
        let bookmarks = (10..<19).map { bookmark(page($0)) }
        let history = (20..<29).map { visit(page($0)) }
        let many = (0..<9).map { index in Command(id: .reload, title: "Deploy \(index)", key: "", modifiers: [], isReserved: false) {} }
        let sections = SwitcherModel.rows(query: "deploy", tabs: tabs, bookmarks: bookmarks, history: history, commands: many).map(\.section)
        #expect(sections.filter { $0 == "Tabs" }.count == 5)
        #expect(sections.filter { $0 == "Bookmarks" }.count == 3)
        #expect(sections.filter { $0 == "History" }.count == 5)
        #expect(sections.filter { $0 == "Commands" }.count == 3)
    }
    @Test func anEmptyQueryStopsAtTheTabLimitToo() {
        let tabs = (0..<9).map { TabRecord(url: page($0)) }
        #expect(SwitcherModel.rows(query: "", tabs: tabs, bookmarks: [], history: [], commands: commands).count == 5)
    }
    @Test func aURLGoesAfterTheTabsAndASearchGoesAboveTheCommands() {
        let tab = TabRecord(url: URL(string: "https://apple.com/mac"), title: "Mac")
        let mark = Bookmark(id: UUID(), title: "Apple", url: URL(string: "https://apple.com/store")!, folder: nil)
        let seen = HistoryEntry(url: URL(string: "https://apple.com/tv")!, title: "Apple TV", visitCount: 1, lastVisit: .now)
        let command = Command(id: .reload, title: "apple.com things", key: "", modifiers: [], isReserved: false) {}
        let address = SwitcherModel.rows(query: "apple.com", tabs: [tab], bookmarks: [mark], history: [seen], commands: [command])
        #expect(address.map(\.section) == ["Tabs", "", "Bookmarks", "History", "Commands"])
        #expect(address[1].target == .address(.url(URL(string: "https://apple.com")!)))

        let search = SwitcherModel.rows(query: "apple", tabs: [tab], bookmarks: [mark], history: [seen], commands: [command])
        #expect(search.map(\.section) == ["Tabs", "Bookmarks", "History", "", "Commands"])
        guard case .address(.search) = search[3].target else {
            Issue.record("expected the search row above the commands")
            return
        }
    }
    @Test func surroundingSpacesDontChangeTheMatch() {
        let tab = TabRecord(url: nil, title: "Deploy guide")
        #expect(SwitcherModel.rows(query: "  dep ", tabs: [tab], bookmarks: [], history: [], commands: []).first?.target == .tab(tab.id))
        #expect(SwitcherModel.rows(query: "   ", tabs: [tab], bookmarks: [], history: [], commands: commands).map(\.target) == [.tab(tab.id)])
    }
    @Test func tabsMatchByURLAndUntitledTabsShowTheirHost() {
        let tab = TabRecord(url: URL(string: "https://docs.example.com/deploy"))
        let row = SwitcherModel.rows(query: "DEPLOY", tabs: [tab], bookmarks: [], history: [], commands: []).first
        #expect(row?.target == .tab(tab.id))
        #expect(row?.title == "docs.example.com")
        #expect(row?.subtitle == "https://docs.example.com/deploy")
    }
    @Test func aPageThatsOpenShowsOnlyAsItsTab() {
        let url = page(1)
        let tab = TabRecord(url: url, title: "Deploy")
        let result = SwitcherModel.rows(query: "dep", tabs: [tab], bookmarks: [bookmark(url)], history: [visit(url)], commands: [])
        #expect(result.filter { $0.target == .url(url) }.isEmpty)
        #expect(result.first?.target == .tab(tab.id))
    }
    @Test func aTypedAddressIsntRepeatedByItsBookmarkOrHistory() {
        let url = URL(string: "https://apple.com")!
        let mark = Bookmark(id: UUID(), title: "Apple", url: url, folder: nil)
        let result = SwitcherModel.rows(query: "apple.com", tabs: [], bookmarks: [mark], history: [visit(url)], commands: [])
        #expect(result.map(\.target) == [.address(.url(url))])
    }
    @Test func aTypedAddressThatsOpenShowsOnlyAsItsTab() {
        let url = URL(string: "https://apple.com")!
        let tab = TabRecord(url: url, title: "Apple")
        let result = SwitcherModel.rows(query: "https://apple.com", tabs: [tab], bookmarks: [], history: [visit(url)], commands: [])
        #expect(result.map(\.target) == [.tab(tab.id)])
    }
    /// A bookmark past the limit isn't on screen, so history is free to show that page.
    @Test func onlyPagesActuallyListedDropOutOfHistory() {
        let bookmarks = (0..<4).map { bookmark(page($0)) }
        let result = SwitcherModel.rows(query: "dep", tabs: [], bookmarks: bookmarks, history: [visit(page(3))], commands: [])
        #expect(result.filter { $0.section == "History" }.map(\.target) == [.url(page(3))])
    }
    @Test func historyWithNoTitleStillSaysWhatItIs() {
        let entry = HistoryEntry(url: page(1), title: "", visitCount: 1, lastVisit: .now)
        #expect(SwitcherModel.rows(query: "dep", tabs: [], bookmarks: [], history: [entry], commands: []).first?.title == page(1).absoluteString)
    }
}

@Suite struct SwitcherListTests {
    let rows = [
        SwitcherRow(target: .command(.back), title: "One", subtitle: "", section: "Tabs"),
        SwitcherRow(target: .command(.forward), title: "Two", subtitle: "", section: "Bookmarks"),
        SwitcherRow(target: .command(.reload), title: "Three", subtitle: "", section: "Bookmarks"),
    ]

    @Test func upAndDownSkipSectionHeadersAndStopAtTheEnds() {
        let list = SwitcherList(selectsFirstRow: true)
        list.show(rows)
        #expect(list.selection == rows[0])
        list.moveSelection(by: 1)
        #expect(list.selection == rows[1])
        list.moveSelection(by: 1)
        list.moveSelection(by: 1)
        #expect(list.selection == rows[2])
        list.moveSelection(by: -1)
        #expect(list.selection == rows[1])
        list.moveSelection(by: -1)
        list.moveSelection(by: -1)
        #expect(list.selection == rows[0])
    }
    @Test func aListWithNoDefaultStartsEmptyAndCanGoBackToEmpty() {
        let list = SwitcherList(selectsFirstRow: false)
        list.show(rows)
        #expect(list.selection == nil)
        list.moveSelection(by: -1)
        #expect(list.selection == nil)
        list.moveSelection(by: 1)
        #expect(list.selection == rows[0])
        list.moveSelection(by: -1)
        #expect(list.selection == nil)
    }
    @Test func aHeaderCantBeChosen() {
        let list = SwitcherList(selectsFirstRow: true)
        list.show(rows)
        var chosen: [SwitcherRow] = []
        list.onChoose = { chosen.append($0) }
        list.chooseRow(0)
        list.chooseRow(2)
        list.chooseRow(99)
        #expect(chosen.isEmpty)
        list.chooseRow(1)
        list.chooseRow(3)
        #expect(chosen == [rows[0], rows[1]])
    }
    /// A row with no section of its own mustn't take the next header with it, or the commands would read as part of the search.
    @Test func theSectionAfterASectionlessRowStillGetsItsHeader() {
        let visit = SwitcherRow(target: .url(URL(string: "https://example.com")!), title: "Page", subtitle: "", section: "History")
        let search = SwitcherRow(target: .command(.find), title: "word", subtitle: "Search Google", section: "")
        let command = SwitcherRow(target: .command(.reload), title: "Command", subtitle: "", section: "Commands")
        func chosenRows(_ shown: [SwitcherRow], count: Int) -> [SwitcherRow?] {
            let list = SwitcherList(selectsFirstRow: true)
            list.show(shown)
            return (0..<count).map { index in
                var chosen: SwitcherRow?
                list.onChoose = { chosen = $0 }
                list.chooseRow(index)
                return chosen
            }
        }
        #expect(chosenRows([visit, search, command], count: 5) == [nil, visit, search, nil, command])
        #expect(chosenRows([search, command], count: 3) == [search, nil, command])
    }
    @Test func noRowsMeansNothingToMoveThrough() {
        let list = SwitcherList(selectsFirstRow: true)
        list.show([])
        list.moveSelection(by: 1)
        #expect(list.selection == nil)
    }
    @Test func theSelectedRowShowsAFillAndOnlyThatRow() {
        let list = SwitcherList(selectsFirstRow: true)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        list.show(rows)
        list.layoutSubtreeIfNeeded()
        func fills() -> Int { list.subviewsDeep.filter { $0 is ActiveFill && !$0.isHidden }.count }
        #expect(fills() == 1)
        list.moveSelection(by: 1)
        #expect(fills() == 1)
    }
    @Test func eachRowIsNamedAndTheChosenOneIsSelected() throws {
        let list = SwitcherList(selectsFirstRow: true)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        list.show(rows)
        list.layoutSubtreeIfNeeded()
        let table = try #require(list.subviewsDeep.compactMap { $0 as? NSTableView }.first)
        #expect(accessibleRows(of: table).map(\.label) == ["Tabs", "One", "Bookmarks", "Two", "Three"])
        #expect(accessibleRows(of: table).map(\.isSelected) == [false, true, false, false, false])
    }
    /// Cells are recycled between headers and rows, so a name left from the last use would be read out.
    @Test func aRecycledCellTakesTheNameOfWhatItShowsNow() throws {
        let list = SwitcherList(selectsFirstRow: true)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        let window = NSWindow(contentRect: list.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = list
        list.show(rows)
        window.displayIfNeeded()
        let table = try #require(list.subviewsDeep.compactMap { $0 as? NSTableView }.first)

        let renamed = [SwitcherRow(target: .command(.find), title: "Four", subtitle: "", section: "History")] + rows.dropFirst().map {
            SwitcherRow(target: $0.target, title: $0.title, subtitle: $0.subtitle, section: "")
        }
        list.show(renamed)
        window.displayIfNeeded()
        #expect(accessibleRows(of: table).map(\.label) == ["History", "Four", "Two", "Three"])
    }
    @Test func theListNeverTakesTheKeyboard() throws {
        let table = try #require(SwitcherList(selectsFirstRow: true).subviewsDeep.compactMap { $0 as? NSTableView }.first)
        #expect(!table.acceptsFirstResponder)
    }
    /// A hosted window gets no clicks, so `chooseRow` stands in for them above. This is the link from a real one.
    @Test func aClickOnTheTableComesToTheList() throws {
        let list = SwitcherList(selectsFirstRow: true)
        let table = try #require(list.subviewsDeep.compactMap { $0 as? NSTableView }.first)
        #expect(table.target === list)
        #expect(list.responds(to: table.action))
    }
}
