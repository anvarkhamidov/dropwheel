import XCTest
@testable import DropwheelCore

final class ClipboardStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testNewestFirstAndDuplicatesMoveToTop() {
        let store = ClipboardStore(directory: dir)
        store.addText("first")
        store.addText("second")
        store.addText("first")
        XCTAssertEqual(store.items.map(\.text), ["first", "second"], "повтор не дублируется, а поднимается наверх")
    }

    func testBlankAndHugeTextIsIgnored() {
        let store = ClipboardStore(directory: dir)
        XCTAssertNil(store.addText("   \n\t"))
        XCTAssertNil(store.addText(String(repeating: "a", count: ClipboardStore.maxTextLength + 1)))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLimitDropsOldestUnpinnedButKeepsPinned() {
        let store = ClipboardStore(directory: dir, limit: 2)
        let pinned = store.addText("keep me")!
        store.togglePin(pinned.id)
        store.addText("a")
        store.addText("b")
        store.addText("c")
        XCTAssertEqual(Set(store.items.compactMap(\.text)), ["keep me", "c", "b"])
    }

    func testSearchMatchesTextFileNamesAndSourceAppPinnedFirst() {
        let store = ClipboardStore(directory: dir)
        store.addText("Invoice number 42", source: ("com.apple.mail", "Mail"))
        store.addFiles([URL(fileURLWithPath: "/tmp/Report Q3.pdf")])
        let note = store.addText("grocery list")!
        store.togglePin(note.id)

        XCTAssertEqual(store.search("invoice").map(\.text), ["Invoice number 42"])
        XCTAssertEqual(store.search("report").first?.kind, .files)
        XCTAssertEqual(store.search("mail").count, 1, "ищет и по приложению-источнику")
        XCTAssertEqual(store.search("").first?.id, note.id, "закреплённое сверху")
    }

    func testImageIsStoredOnDiskAndRemovedWithItem() throws {
        let store = ClipboardStore(directory: dir)
        let item = try XCTUnwrap(store.addImage(png: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), width: 640, height: 480))
        let url = try XCTUnwrap(store.imageURL(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(item.title, "Изображение 640 × 480")
        store.remove(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHistorySurvivesRestart() {
        let store = ClipboardStore(directory: dir)
        store.addText("persisted")
        let pinned = store.addFiles([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])!
        store.togglePin(pinned.id)

        let reopened = ClipboardStore(directory: dir)
        XCTAssertEqual(reopened.items.count, 2)
        XCTAssertEqual(reopened.items.first(where: { $0.kind == .files })?.pinned, true)
        XCTAssertEqual(reopened.items.first(where: { $0.kind == .files })?.title, "2 файла: a.png, b.png")
    }

    func testFileCountPlurals() {
        XCTAssertEqual(ClipItem.files(2), "2 файла")
        XCTAssertEqual(ClipItem.files(5), "5 файлов")
        XCTAssertEqual(ClipItem.files(11), "11 файлов")
        XCTAssertEqual(ClipItem.files(21), "21 файл")
        XCTAssertEqual(ClipItem.files(24), "24 файла")
    }

    func testClearKeepsPinnedByDefault() {
        let store = ClipboardStore(directory: dir)
        let keep = store.addText("pinned")!
        store.togglePin(keep.id)
        store.addText("temporary")
        store.clear()
        XCTAssertEqual(store.items.map(\.text), ["pinned"])
        store.clear(keepPinned: false)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testPasswordManagerContentIsIgnored() {
        XCTAssertTrue(ClipboardStore.shouldIgnore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardStore.shouldIgnore(types: ["com.agilebits.onepassword"]))
        XCTAssertFalse(ClipboardStore.shouldIgnore(types: ["public.utf8-plain-text", "public.html"]))
    }
}
