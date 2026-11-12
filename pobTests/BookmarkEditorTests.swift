import AppKit
import Testing
@testable import pob

@Suite struct BookmarkEditorTests {
    private func editor(
        name: String = "Old name",
        address: URL? = URL(string: "https://old.example/"),
        folder: String? = nil,
        folders: [String] = [],
        onSave: @escaping (BookmarkEditor.Entry) -> Void = { _ in }
    ) -> BookmarkEditor {
        let editor = BookmarkEditor(heading: "Edit Bookmark", name: name, address: address, folder: folder, folders: folders, focus: .name, onSave: onSave)
        _ = editor.view
        return editor
    }

    @Test func anAddressIsReadLikeTheAddressField() {
        #expect(BookmarkEditor.entry(name: "X", address: "example.com", folder: nil, original: nil)?.url == URL(string: "https://example.com"))
        #expect(BookmarkEditor.entry(name: "X", address: "https://a.example/p?q=1", folder: nil, original: nil)?.url == URL(string: "https://a.example/p?q=1"))
    }

    @Test func wordsAndEmptyAddressesAreRefused() {
        for text in ["two words", "", "   ", "javascript:alert(1)"] {
            #expect(BookmarkEditor.entry(name: "X", address: text, folder: nil, original: nil) == nil)
        }
    }

    @Test func aBlankNameBecomesTheHost() {
        #expect(BookmarkEditor.entry(name: "  ", address: "example.com", folder: nil, original: nil)?.title == "example.com")
        #expect(BookmarkEditor.entry(name: "  Mine ", address: "example.com", folder: nil, original: nil)?.title == "Mine")
    }

    @Test func anAddressLeftAsItWasIsKept() throws {
        let original = try #require(URL(string: "data:text/html,hi"))
        #expect(BookmarkEditor.entry(name: "X", address: "data:text/html,hi", folder: nil, original: original)?.url == original)
        #expect(BookmarkEditor.entry(name: "X", address: "data:text/html,bye", folder: nil, original: original) == nil)
    }

    @Test func theEditorShowsWhatItWasGiven() {
        let plain = editor(name: "Mine", address: URL(string: "https://mine.example/"))
        #expect(plain.nameField.stringValue == "Mine")
        #expect(plain.addressField.stringValue == "https://mine.example/")
        #expect(plain.folderButton.isHidden)

        let filed = editor(folder: "Home", folders: ["Work", "Home"])
        #expect(!filed.folderButton.isHidden)
        #expect(filed.folderButton.itemTitles == ["No Folder", "Work", "Home"])
        #expect(filed.folderButton.titleOfSelectedItem == "Home")

        let loose = editor(folder: nil, folders: ["Work"])
        #expect(loose.folderButton.titleOfSelectedItem == "No Folder")
    }

    @Test func aFolderNamedNoFolderIsStillListed() {
        let editor = editor(folder: "No Folder", folders: ["No Folder"])
        #expect(editor.folderButton.numberOfItems == 2)
        #expect(editor.folderButton.indexOfSelectedItem == 1)
    }

    @Test func savingHandsOverWhatsInTheFields() {
        var saved: [BookmarkEditor.Entry] = []
        let editor = editor(folders: ["Work"]) { saved.append($0) }
        editor.nameField.stringValue = "New name"
        editor.addressField.stringValue = "example.org"
        editor.folderButton.selectItem(at: 1)
        editor.saveButton.performClick(nil)
        #expect(saved == [BookmarkEditor.Entry(title: "New name", url: URL(string: "https://example.org")!, folder: "Work")])

        editor.folderButton.selectItem(at: 0)
        editor.saveButton.performClick(nil)
        #expect(saved.last?.folder == nil)
        #expect(saved.count == 2)
    }

    @Test func aBadAddressSavesNothing() {
        var saved: [BookmarkEditor.Entry] = []
        let editor = editor { saved.append($0) }
        editor.addressField.stringValue = "two words"
        editor.saveButton.performClick(nil)
        #expect(saved.isEmpty)
    }

    @Test func theEditorSavesOnReturn() {
        let bookmark = editor()
        let folder = FolderEditor(heading: "New Folder", name: "") { _ in true }
        _ = folder.view
        #expect(bookmark.saveButton.keyEquivalent == "\r")
        #expect(folder.saveButton.keyEquivalent == "\r")
    }

    @Test func theFolderEditorHandsOverTheName() {
        var names: [String] = []
        var accepts = true
        let editor = FolderEditor(heading: "Rename Folder", name: "Work") { name in
            names.append(name)
            return accepts
        }
        _ = editor.view
        #expect(editor.nameField.stringValue == "Work")
        editor.nameField.stringValue = "Jobs"
        editor.saveButton.performClick(nil)
        #expect(names == ["Jobs"])

        accepts = false
        editor.nameField.stringValue = "Taken"
        editor.saveButton.performClick(nil)
        #expect(names == ["Jobs", "Taken"])
        #expect(editor.nameField.stringValue == "Taken")
    }
}
