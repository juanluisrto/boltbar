import AppKit
import XCTest
@testable import BoltbarNative

@MainActor final class ChatScrollObserverTests: XCTestCase {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    func testUserScrollPausesFollowingUntilBackAtBottom() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
        scroll.documentView = document
        let tracking = ChatScrollTrackingView(frame: document.bounds)
        document.addSubview(tracking)
        var follows = true
        tracking.onFollowChange = { follows = $0 }
        tracking.attachToScrollView()

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertTrue(follows)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertFalse(follows)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertTrue(follows)

        // Streaming increases document height without moving the viewport.
        document.frame.size.height = 600
        XCTAssertTrue(follows)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertFalse(follows)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertTrue(follows)
    }
}
