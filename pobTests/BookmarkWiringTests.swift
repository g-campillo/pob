import AppKit
import Foundation
import Testing
@testable import pob

/// The addresses whose icon was asked for, in place of the network.
final class IconRequests { var urls: [URL] = [] }

/// What the delete-folder sheet was asked, and what it answers.
private final class DeleteQuestions {
    var asked: [(name: String, count: Int)] = []
    var answer = false
}

@Suite(.timeLimit(.minutes(1))) struct BookmarkWiringTests {
    let page = URL(string: "https://localhost/page")!

    /// A window on a page titled "Page", with the rail out and the section open. Icons are only recorded.
    func make(profile: Profile = .temporary()) async -> (WindowController, IconRequests) {
        let tabs = TabManager(profile: profile, keepsSpare: false)
        tabs.updateFavicon = { _, _, _ in }
        let tab = tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        await finishLoading(tab) { tab.webView.loadSimulatedRequest(URLRequest(url: page), responseHTML: "<title>Page</title>") }
        _ = await eventually { tab.title == "Page" }
        let requests = IconRequests()
        controller.fetchBookmarkIcon = { _, url in requests.urls.append(url) }
        controller.revealRailImmediately()
        controller.rail.bookmarks.setExpanded(true, animated: false)
        return (controller, requests)
    }

    /// A popover only shows, and so only reports closing, over a window that's showing. Far outside every display, as
    /// `offscreenWindow()` does. The caller closes it.
    private func putOnScreen(_ controller: WindowController) {
        controller.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        controller.window?.orderFrontRegardless()
    }

    private func bookmarkEditor(in controller: WindowController) throws -> BookmarkEditor {
        let editor = try #require(controller.openPopover?.contentViewController as? BookmarkEditor)
        _ = editor.view
        return editor
    }

    private func folderEditor(in controller: WindowController) throws -> FolderEditor {
        let editor = try #require(controller.openPopover?.contentViewController as? FolderEditor)
        _ = editor.view
        return editor
    }

    /// Runs the right-click item on the row as choosing it would.
    private func chooseItem(_ title: String, onRow row: Int, in controller: WindowController) {
        #expect(choose(title, in: controller.rail.bookmarks.menu(forRow: row)))
    }

    private func recordQuestions(in controller: WindowController) -> DeleteQuestions {
        let questions = DeleteQuestions()
        controller.confirmDeleteFolder = { _, name, count in
            questions.asked.append((name, count))
            return questions.answer
        }
        return questions
    }

    // MARK: Adding

    @Test func thePlusButtonSavesThePageItsOn() async throws {
        let (controller, requests) = await make()
        putOnScreen(controller)
        defer { controller.close() }
        let store = controller.tabs.profile.bookmarks
        controller.rail.bookmarks.setExpanded(false, animated: false) // so only saving can open it
        controller.rail.bookmarks.addButton.performClick(nil)
        #expect(controller.openPopover?.isShown == true)
        let editor = try bookmarkEditor(in: controller)
        #expect(editor.nameField.stringValue == "Page")
        #expect(editor.addressField.stringValue == page.absoluteString)

        editor.saveButton.performClick(nil)
        let saved = try #require(store.all.first)
        #expect(store.all.count == 1)
        #expect(saved.title == "Page" && saved.url == page && saved.folder == nil)
        #expect(controller.rail.bookmarks.isExpanded)
        #expect(controller.rail.bookmarks.rows.contains { $0.key == .bookmark(saved.id) })
        #expect(await eventually { controller.openPopover == nil })
        #expect(await eventually { requests.urls == [page] })
    }
    @Test func thePlusButtonCanSaveIntoAFolder() async throws {
        let (controller, _) = await make()
        let store = controller.tabs.profile.bookmarks
        store.addFolder("Work")
        controller.rail.bookmarks.addButton.performClick(nil)
        let editor = try bookmarkEditor(in: controller)
        editor.folderButton.selectItem(withTitle: "Work")

        editor.saveButton.performClick(nil)
        let saved = try #require(store.all.first)
        #expect(saved.folder == "Work")
        #expect(controller.rail.bookmarks.rows == [.folder("Work", isOpen: true), .bookmark(saved, inFolder: true)])
    }
    @Test func aBadAddressKeepsTheEditorUp() async throws {
        let (controller, requests) = await make()
        controller.rail.bookmarks.addButton.performClick(nil)
        let popover = try #require(controller.openPopover)
        let editor = try bookmarkEditor(in: controller)
        editor.addressField.stringValue = "two words"

        editor.saveButton.performClick(nil)
        #expect(controller.tabs.profile.bookmarks.all.isEmpty)
        #expect(controller.openPopover === popover)
        #expect(requests.urls.isEmpty)
    }

    // MARK: Changing a bookmark

    @Test func renamingChangesOnlyTheName() async throws {
        let (controller, requests) = await make()
        let store = controller.tabs.profile.bookmarks
        store.add(title: "Page", url: page, folder: nil)
        chooseItem("Rename…", onRow: 0, in: controller)
        let editor = try bookmarkEditor(in: controller)
        editor.nameField.stringValue = "Mine"

        editor.saveButton.performClick(nil)
        #expect(store.all.map(\.title) == ["Mine"])
        #expect(store.all.map(\.url) == [page])
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.urls.isEmpty)
    }
    @Test func editingTheAddressFetchesTheNewIcon() async throws {
        let (controller, requests) = await make()
        let store = controller.tabs.profile.bookmarks
        store.add(title: "Page", url: page, folder: nil)
        chooseItem("Edit Address…", onRow: 0, in: controller)
        let editor = try bookmarkEditor(in: controller)
        editor.addressField.stringValue = "example.org"

        editor.saveButton.performClick(nil)
        let address = URL(string: "https://example.org")!
        #expect(store.all.map(\.url) == [address])
        #expect(store.all.map(\.title) == ["Page"])
        #expect(await eventually { requests.urls == [address] })
    }
    @Test func bookmarkingThePageFetchesItsIconOnce() async throws {
        let (controller, requests) = await make()
        let store = controller.tabs.profile.bookmarks
        controller.perform(.bookmarkPage)
        #expect(store.all.map(\.url) == [page])
        #expect(await eventually { requests.urls == [page] })

        controller.perform(.bookmarkPage)
        #expect(store.all.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.urls.count == 1)
    }

    // MARK: Folders

    @Test func aNewFolderComesFromTheHeader() async throws {
        let (controller, _) = await make()
        putOnScreen(controller)
        defer { controller.close() }
        let store = controller.tabs.profile.bookmarks
        controller.rail.bookmarks.newFolderButton.performClick(nil)
        #expect(controller.openPopover?.isShown == true)
        let editor = try folderEditor(in: controller)
        editor.nameField.stringValue = "Work"

        editor.saveButton.performClick(nil)
        #expect(store.folders == ["Work"])
        #expect(await eventually { controller.openPopover == nil })
        #expect(controller.rail.bookmarks.rows.contains(.folder("Work", isOpen: false)))

        controller.rail.bookmarks.newFolderButton.performClick(nil)
        let popover = try #require(controller.openPopover)
        let again = try folderEditor(in: controller)
        again.nameField.stringValue = " Work "
        again.saveButton.performClick(nil)
        #expect(store.folders == ["Work"])
        #expect(controller.openPopover === popover)
    }
    @Test func renamingAFolderTakesItsBookmarks() async throws {
        let (controller, _) = await make()
        let store = controller.tabs.profile.bookmarks
        store.add(title: "Page", url: page, folder: "Work")
        chooseItem("Rename Folder…", onRow: 0, in: controller)
        let editor = try folderEditor(in: controller)
        #expect(editor.nameField.stringValue == "Work")
        editor.nameField.stringValue = "Jobs"

        editor.saveButton.performClick(nil)
        #expect(store.folders == ["Jobs"])
        #expect(store.all.map(\.folder) == ["Jobs"])
    }
    @Test func deletingAFolderWithBookmarksAsksFirst() async throws {
        let (controller, _) = await make()
        let store = controller.tabs.profile.bookmarks
        store.add(title: "Page", url: page, folder: "Work")
        let questions = recordQuestions(in: controller)

        chooseItem("Delete Folder", onRow: 0, in: controller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.folders == ["Work"])
        #expect(store.all.count == 1)
        #expect(questions.asked.map(\.name) == ["Work"])
        #expect(questions.asked.map(\.count) == [1])

        questions.answer = true
        chooseItem("Delete Folder", onRow: 0, in: controller)
        #expect(await eventually { store.folders.isEmpty && store.all.isEmpty })
    }
    @Test func anEmptyFolderGoesWithoutAsking() async throws {
        let (controller, _) = await make()
        let store = controller.tabs.profile.bookmarks
        store.addFolder("Empty")
        let questions = recordQuestions(in: controller)

        chooseItem("Delete Folder", onRow: 0, in: controller)
        #expect(store.folders.isEmpty)
        #expect(questions.asked.isEmpty)
    }

    // MARK: The rail and other windows

    @Test func theRailStaysOutWhileAnEditorIsUp() async throws {
        let (controller, _) = await make()
        controller.rail.bookmarks.addButton.performClick(nil)
        #expect(controller.openPopover != nil)

        controller.rail.onPointerExit?()
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.railState.visibility == .hover)
        #expect(!controller.rail.isHidden)
    }
    @Test func anIconThatLandsShowsInEveryWindowOfTheProfile() async throws {
        let profile = Profile.temporary()
        let (first, _) = await make(profile: profile)
        // No page, because a page's late updates refresh the rail too, and only the store's word should reach this one.
        let second = WindowController(appearance: testAppearance(), tabs: TabManager(profile: profile, keepsSpare: false))
        second.revealRailImmediately()
        second.rail.bookmarks.setExpanded(true, animated: false)
        let folder = profile.directory.appending(path: "favicons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        first.fetchBookmarkIcon = { _, url in try? writeIcon(forHost: url.host() ?? "", in: folder) }

        first.perform(.bookmarkPage)
        // Laid out with the row in view, or the table can drop its view and the refresh never reaches the one held here.
        second.window?.layoutIfNeeded()
        let table = try #require(second.rail.bookmarks.subviewsDeep.compactMap { $0 as? NSTableView }.first)
        // The row is there while the icon is missing, so only the store's word can bring the icon to it.
        let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(await eventually {
            guard let icon = profile.favicons.image(forHost: "localhost") else { return false }
            return row.subviews.compactMap { $0 as? NSImageView }.first?.image === icon
        })
    }
    @Test func aBookmarkSavedInAPrivateWindowGoesToItsParent() async throws {
        let parent = Profile.temporary()
        let (controller, requests) = await make(profile: .makePrivate(from: parent))
        controller.rail.bookmarks.addButton.performClick(nil)
        let editor = try bookmarkEditor(in: controller)

        editor.saveButton.performClick(nil)
        #expect(parent.bookmarks.all.map(\.url) == [page])
        #expect(await eventually { requests.urls == [page] })
    }
}
