import XCTest
@testable import JetKVMCore

final class ClipboardSyncTests: XCTestCase {
    private func select(_ data: [String: Data]) -> [String: Data]? {
        ClipboardPolicy.select(types: Array(data.keys)) { data[$0] }
    }

    func testSelectsTheSyncedTypes() {
        let text = Data("hello".utf8)
        let items = select(["public.utf8-plain-text": text, "public.html": Data("<b>hello</b>".utf8),
                            "com.apple.webarchive": Data(count: 10)])
        XCTAssertEqual(items?.keys.sorted(), ["public.html", "public.utf8-plain-text"])
        XCTAssertEqual(items?["public.utf8-plain-text"], text)
    }

    func testLeavesPasswordsAlone() {
        XCTAssertNil(select(["public.utf8-plain-text": Data("secret".utf8), "org.nspasteboard.ConcealedType": Data()]))
        XCTAssertNil(select(["public.utf8-plain-text": Data("one-off".utf8), "org.nspasteboard.TransientType": Data()]))
        XCTAssertNil(select(["com.apple.webarchive": Data(count: 10)]))
    }

    func testAPasteOnPurposeKeepsTransientTextMarked() {
        // What a dictation app pastes (Superwhisper marks it transient).
        let data = ["public.utf8-plain-text": Data("dictated".utf8), "org.nspasteboard.TransientType": Data()]
        let items = ClipboardPolicy.select(types: Array(data.keys), includingPrivate: true) { data[$0] }
        XCTAssertEqual(items, data)
        XCTAssertNil(ClipboardPolicy.select(types: ["org.nspasteboard.TransientType"], includingPrivate: true) { data[$0] })
    }

    func testPrefersPNGOverTheSameImageAsTIFF() {
        let items = select(["public.png": Data(count: 100), "public.tiff": Data(count: 1000)])
        XCTAssertEqual(items?.keys.sorted(), ["public.png"])
        XCTAssertEqual(select(["public.tiff": Data(count: 1000)])?.keys.sorted(), ["public.tiff"])
    }

    func testLeavesOutWhatDoesNotFitImagesFirst() {
        let big = Data(count: ClipboardPolicy.maxBytes)
        let items = select(["public.utf8-plain-text": Data("caption".utf8), "public.png": big])
        XCTAssertEqual(items?.keys.sorted(), ["public.utf8-plain-text"])
    }

    func testParamsAndEventRoundTrip() throws {
        let items = ["public.utf8-plain-text": Data("äö 🚀".utf8), "public.png": Data([0, 1, 2, 255])]
        let params = ClipboardPolicy.params(items)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params))
        XCTAssertEqual(ClipboardPolicy.items(fromClip: json), items)
        XCTAssertNil(ClipboardPolicy.items(fromClip: ["items": [:]]))
        XCTAssertNil(ClipboardPolicy.items(fromClip: "nonsense"))
    }

    func testRemoteClipsCarryOnlyTheSyncedTypes() {
        let text = Data("hi".utf8).base64EncodedString()
        let clip: [String: Any] = ["items": ["public.utf8-plain-text": text,
                                             "public.file-url": Data("file:///etc/passwd".utf8).base64EncodedString()]]
        XCTAssertEqual(ClipboardPolicy.items(fromClip: clip)?.keys.sorted(), ["public.utf8-plain-text"])
        let secret: [String: Any] = ["items": ["public.utf8-plain-text": text, "org.nspasteboard.ConcealedType": ""]]
        XCTAssertNil(ClipboardPolicy.items(fromClip: secret))
    }

    func testDevicesSavedBeforeClipboardSyncStillLoad() throws {
        let old = #"{"id":"a","name":"Mini","addresses":["192.168.1.107"],"modifierProfile":"mac","invertScroll":false}"#
        let device = try JSONDecoder().decode(Device.self, from: Data(old.utf8))
        XCTAssertNil(device.clipboardSync)

        var synced = device
        synced.clipboardSync = ClipboardSync(user: "zoma", computerName: "Mac mini", hostKey: "ssh-ed25519 AAAA")
        let decoded = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(synced))
        XCTAssertEqual(decoded.clipboardSync, synced.clipboardSync)
        XCTAssertEqual(decoded.clipboardSync?.enabled, true)
    }
}
