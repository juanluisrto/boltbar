import AppKit
import SwiftUI

struct HistoryPane: View {
    @ObservedObject var model: ChatModel
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: close) { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("Back to chat")
                Text("Previous chats").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { close(); model.newConversation?() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 15)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("New chat (⌘N)").accessibilityLabel("New chat")
            }
            ZStack {
                HistoryTable(items: model.filteredHistory, query: $model.historyQuery, selectedID: $model.selectedHistoryID, open: { id in
                    Task { if await model.openConversation(id) { close(); model.focusComposer?() } }
                }, close: close)
                .frame(height: model.historyHeight + 38)
                .disabled(model.openingConversation)
                if model.filteredHistory.isEmpty {
                    Text(model.searchingHistory ? "Searching…" : model.history.isEmpty
                         ? "Your conversations will appear here after you send a message."
                         : "No matching conversations")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 38).allowsHitTesting(false)
                }
            }
            Text("↑ ↓ select · → / Return open · ← back").font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).preferredColorScheme(.dark)
            .onMoveCommand { if $0 == .left { close() } }
    }
}

final class ConversationTableView: NSTableView {
    var activate: (() -> Void)?
    var dismiss: (() -> Void)?
    var editSearch: ((NSEvent) -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 124: activate?()
        case 53, 123: dismiss?()
        case 125, 126: super.keyDown(with: event)
        default:
            if let characters = event.characters, !characters.isEmpty,
               !characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
                editSearch?(event)
            } else { super.keyDown(with: event) }
        }
    }
}

final class HistoryBrowserView: NSView {
    let search = NSSearchField(), scroll = HistoryScrollView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "Search all messages"
        search.font = .systemFont(ofSize: 12); search.focusRingType = .none
        search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        search.setAccessibilityLabel("Search conversations")
        for view in [search, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor), search.leadingAnchor.constraint(equalTo: leadingAnchor),
            search.trailingAnchor.constraint(equalTo: trailingAnchor), search.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.search) }
        }
    }
}

final class ConversationRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}

/// SwiftUI supplies the scroll view's real width after makeNSView. Fit the
/// document on every layout, including its first appearance after a resize.
final class HistoryScrollView: NSScrollView {
    private var fittingWidth = false
    override func tile() { super.tile(); fitDocumentWidth() }
    override func layout() { super.layout(); fitDocumentWidth() }
    func fitDocumentWidth() {
        guard !fittingWidth, let table = documentView as? NSTableView,
              let column = table.tableColumns.first, contentView.bounds.width > 0 else { return }
        fittingWidth = true
        defer { fittingWidth = false }
        let width = contentView.bounds.width
        if abs(column.width - width) > 0.5 { column.width = width }
        if abs(table.frame.width - width) > 0.5 { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if contentView.bounds.origin.x != 0 {
            contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
    }
}

struct HistoryTable: NSViewRepresentable {
    let items: [ConversationSummary]
    @Binding var query: String
    @Binding var selectedID: UUID?
    let open: (UUID) -> Void
    let close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> HistoryBrowserView {
        let browser = HistoryBrowserView()
        browser.search.stringValue = query; browser.search.delegate = context.coordinator
        let table = ConversationTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.minWidth = 0; table.addTableColumn(column)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = nil; table.rowHeight = 44; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.style = .plain; table.focusRingType = .none
        table.allowsMultipleSelection = false; table.allowsEmptySelection = false
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.action = #selector(Coordinator.clicked(_:))
        table.activate = { [weak coordinator = context.coordinator, weak table] in
            if let table { coordinator?.activate(row: table.selectedRow) }
        }
        table.dismiss = close; table.setAccessibilityLabel("Previous conversations")
        table.editSearch = { [weak browser] event in
            guard let browser else { return }
            browser.window?.makeFirstResponder(browser.search)
            browser.search.currentEditor()?.keyDown(with: event)
        }
        context.coordinator.table = table; context.coordinator.search = browser.search
        let scroll = browser.scroll; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false; scroll.horizontalScrollElasticity = .none
        scroll.drawsBackground = false; scroll.documentView = table
        context.coordinator.reload(items)
        return browser
    }
    func updateNSView(_ browser: HistoryBrowserView, context: Context) {
        let scroll = browser.scroll
        guard let table = scroll.documentView as? ConversationTableView else { return }
        context.coordinator.parent = self; table.dismiss = close
        if browser.search.stringValue != query { browser.search.stringValue = query }
        if context.coordinator.items != items {
            context.coordinator.reload(items)
        }
        scroll.fitDocumentWidth()
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
        var parent: HistoryTable
        var items: [ConversationSummary] = []
        weak var table: ConversationTableView?
        weak var search: NSSearchField?
        private var restoringSelection = false
        init(parent: HistoryTable) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { parent.query = search?.stringValue ?? "" }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveDown(_:)): select(delta: 1)
            case #selector(NSResponder.moveUp(_:)): select(delta: -1)
            case #selector(NSResponder.insertNewline(_:)): if let table { activate(row: table.selectedRow) }
            case #selector(NSResponder.moveRight(_:)): if let table { activate(row: table.selectedRow) }
            case #selector(NSResponder.moveLeft(_:)): parent.close()
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.query.isEmpty { parent.close() }
                else { search?.stringValue = ""; parent.query = "" }
            default: return false
            }
            return true
        }
        private func select(delta: Int) {
            guard let table, !items.isEmpty else { return }
            let row = min(items.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        func reload(_ items: [ConversationSummary]) {
            guard let table else { return }
            restoringSelection = true
            defer { restoringSelection = false }
            self.items = items; table.reloadData()
            if !items.isEmpty {
                let row = items.firstIndex { $0.id == parent.selectedID } ?? 0
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !restoringSelection, let table, items.indices.contains(table.selectedRow) else { return }
            parent.selectedID = items[table.selectedRow].id
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ConversationRowView() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = parent.items[row]
            let cell = NSTableCellView()
            let dateText = ConversationDate.label(item.updatedAt)
            let title = NSButton(title: item.title, target: self, action: #selector(openButton(_:)))
            title.tag = row; title.isBordered = false; title.alignment = .left
            title.contentTintColor = .labelColor
            title.setAccessibilityLabel("\(item.title), \(dateText)")
            let date = NSTextField(labelWithString: dateText)
            title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            date.font = .systemFont(ofSize: 11); date.textColor = .secondaryLabelColor
            date.setContentCompressionResistancePriority(.required, for: .horizontal)
            date.setContentHuggingPriority(.required, for: .horizontal)
            let rowView = NSStackView(views: [title, date]); rowView.orientation = .horizontal; rowView.spacing = 12; rowView.distribution = .fill
            rowView.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(rowView)
            NSLayoutConstraint.activate([rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                rowView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        @objc func openButton(_ button: NSButton) { activate(row: button.tag) }
        @objc func clicked(_ table: NSTableView) { activate(row: table.clickedRow) }
        func activate(row: Int) {
            if parent.items.indices.contains(row) { parent.selectedID = parent.items[row].id; parent.open(parent.items[row].id) }
        }
    }
}
