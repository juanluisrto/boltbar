import AppKit
import SwiftUI

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]

    static func parse(_ lines: [String], at start: Int) -> (table: MarkdownTable, end: Int)? {
        guard start + 1 < lines.count else { return nil }
        let headers = cells(lines[start]), separators = cells(lines[start + 1])
        guard lines[start].contains("|"), !headers.isEmpty, headers.count == separators.count,
              separators.allSatisfy({ $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }) else { return nil }
        let alignments: [Alignment] = separators.map {
            $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .trailing) : .leading
        }
        var rows: [[String]] = [], end = start + 2
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty, lines[end].contains("|") {
            let values = cells(lines[end])
            rows.append(Array((values + Array(repeating: "", count: headers.count)).prefix(headers.count)))
            end += 1
        }
        return (MarkdownTable(headers: headers, alignments: alignments, rows: rows), end)
    }

    /// Split structural pipes, preserving escaped pipes and inline code spans.
    static func cells(_ line: String) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var result: [String] = [], cell = "", index = 0, codeTicks = 0, trailingSeparator = false
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                if characters[index + 1] == "|" { cell.append("|") }
                else { cell.append(character); cell.append(characters[index + 1]) }
                index += 2; trailingSeparator = false; continue
            }
            if character == "`" {
                var end = index
                while end < characters.count, characters[end] == "`" { end += 1 }
                let count = end - index
                if codeTicks == 0 { codeTicks = count } else if codeTicks == count { codeTicks = 0 }
                cell += String(repeating: "`", count: count)
                index = end; trailingSeparator = false; continue
            }
            if character == "|", codeTicks == 0 {
                result.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; trailingSeparator = true
            } else { cell.append(character); trailingSeparator = false }
            index += 1
        }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        if characters.first == "|", result.first == "" { result.removeFirst() }
        if trailingSeparator, result.last == "" { result.removeLast() }
        return result
    }
}

private struct TableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MarkdownTableView: View {
    let table: MarkdownTable
    @State private var availableWidth: CGFloat = 0
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    private var widths: [CGFloat] {
        let preferred = table.headers.indices.map { column -> CGFloat in
            let values = [table.headers[column]] + table.rows.map { $0[column] }
            let measured = values.map { (String(inline($0).characters) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width }.max() ?? 0
            return min(280, max(96, ceil(measured) + 24))
        }
        let total = preferred.reduce(0, +), minimum = CGFloat(preferred.count) * 96
        guard availableWidth > 0, minimum <= availableWidth else { return preferred }
        if total <= availableWidth {
            let extra = (availableWidth - total) / CGFloat(preferred.count)
            return preferred.map { $0 + extra }
        }
        let fraction = (availableWidth - minimum) / max(1, total - minimum)
        return preferred.map { 96 + ($0 - 96) * fraction }
    }
    private func alignment(_ column: Int) -> Alignment {
        switch table.alignments[column] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments[column] { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
    private func row(_ cells: [String], widths: [CGFloat], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                Text(inline(cells[column])).font(.system(size: 13, weight: header ? .semibold : .regular))
                    .multilineTextAlignment(textAlignment(column)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(width: widths[column], alignment: alignment(column))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        let widths = widths
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                row(table.headers, widths: widths, header: true).background(.white.opacity(0.07))
                ForEach(table.rows.indices, id: \.self) { index in
                    Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
                    row(table.rows[index], widths: widths, header: false)
                        .background(.white.opacity(index.isMultiple(of: 2) ? 0.02 : 0))
                }
            }.frame(width: widths.reduce(0, +))
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 1))
                .padding(1)
        }.fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: TableWidthKey.self, value: max(0, $0.size.width - 2)) })
            .onPreferenceChange(TableWidthKey.self) { if abs(availableWidth - $0) > 0.5 { availableWidth = $0 } }
    }
}
