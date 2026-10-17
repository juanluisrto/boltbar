import AppKit
import SwiftUI

/// Watches actual scroll movement, so growing streamed content does not look like
/// a user scrolling away from the bottom.
struct ChatScrollObserver: NSViewRepresentable {
    let onFollowChange: (Bool) -> Void

    func makeNSView(context: Context) -> ChatScrollTrackingView {
        let view = ChatScrollTrackingView()
        view.onFollowChange = onFollowChange
        return view
    }

    func updateNSView(_ view: ChatScrollTrackingView, context: Context) {
        view.onFollowChange = onFollowChange
        view.attachToScrollView()
    }
}

final class ChatScrollTrackingView: NSView {
    var onFollowChange: ((Bool) -> Void)?
    private weak var observedScrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachToScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToScrollView()
    }

    override func layout() {
        super.layout()
        attachToScrollView()
    }

    func attachToScrollView() {
        let scrollView = enclosingScrollView
        guard scrollView !== observedScrollView else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        observedScrollView = scrollView
        guard let scrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in self?.reportPosition() }
    }

    private func reportPosition() {
        guard let scrollView = observedScrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let distance = document.isFlipped
            ? document.bounds.maxY - visible.maxY
            : visible.minY - document.bounds.minY
        onFollowChange?(distance <= 12)
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
}
