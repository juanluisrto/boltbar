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
            if model.history.isEmpty {
                Text("Your conversations will appear here after you send a message.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(height: model.historyHeight)
            } else {
                HistoryTable(items: model.history, open: { id in
                    Task { if await model.openConversation(id) { close(); model.focusComposer?() } }
                }, close: close)
                .frame(height: model.historyHeight)
                .disabled(model.openingConversation)
                Text("↑ ↓ to select · Return to open · ← to go back").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).preferredColorScheme(.dark)
            .onMoveCommand { if $0 == .left { close() } }
    }
}

final class ConversationTableView: NSTableView {
    var activate: (() -> Void)?
    var dismiss: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) } }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: activate?()
        case 53, 123: dismiss?()
        default: super.keyDown(with: event)
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

struct HistoryTable: NSViewRepresentable {
    let items: [ConversationSummary]
    let open: (UUID) -> Void
    let close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = ConversationTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.width = 668; column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 44; table.intercellSpacing = .zero
        table.backgroundColor = .clear; table.style = .plain; table.focusRingType = .none
        table.allowsMultipleSelection = false; table.allowsEmptySelection = false
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.action = #selector(Coordinator.clicked(_:))
        table.activate = { [weak coordinator = context.coordinator, weak table] in
            if let table { coordinator?.activate(row: table.selectedRow) }
        }
        table.dismiss = close; table.setAccessibilityLabel("Previous conversations")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = table
        context.coordinator.items = items
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? ConversationTableView else { return }
        context.coordinator.parent = self; table.dismiss = close
        let ids = items.map(\.id)
        if context.coordinator.items != items {
            let previous = context.coordinator.items
            let selected = previous.indices.contains(table.selectedRow) ? previous[table.selectedRow].id : nil
            context.coordinator.items = items; table.reloadData()
            if !ids.isEmpty { table.selectRowIndexes(IndexSet(integer: selected.flatMap { ids.firstIndex(of: $0) } ?? 0), byExtendingSelection: false) }
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: HistoryTable
        var items: [ConversationSummary] = []
        init(parent: HistoryTable) { self.parent = parent }
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
        func activate(row: Int) { if parent.items.indices.contains(row) { parent.open(parent.items[row].id) } }
    }
}
