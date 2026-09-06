import Foundation

struct ToasttyMarkdownTable: Equatable, Sendable {
    enum ColumnAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    struct Row: Identifiable, Equatable, Sendable {
        let id: Int
        var cells: [AttributedString]

        var isHeader: Bool { id == 0 }
        var characterCount: Int { cells.reduce(0) { $0 + $1.characters.count } }
    }

    static let maximumBodyRowsPerChunk = 24

    let columns: [ColumnAlignment]
    var rows: [Row]

    var content: AttributedString {
        var result = AttributedString()
        for row in rows {
            for cell in row.cells { result.append(cell) }
        }
        return result
    }

    /// Keep cells and rows intact; each continuation repeats the header and
    /// shares column widths. A single oversized row may exceed the soft budget.
    func split(rowBudget: Int) -> [Self] {
        guard let header = rows.first else { return [self] }
        var result: [Self] = []
        var currentRows = [header]
        var currentCount = header.characterCount
        for row in rows.dropFirst() {
            if currentRows.count > 1,
               currentCount + row.characterCount > rowBudget
                || currentRows.count - 1 >= Self.maximumBodyRowsPerChunk {
                result.append(Self(columns: columns, rows: currentRows))
                currentRows = [header]
                currentCount = header.characterCount
            }
            currentRows.append(row)
            currentCount += row.characterCount
        }
        result.append(Self(columns: columns, rows: currentRows))
        return result
    }
}

/// Foundation omits runs for empty cells. Column indices preserve those slots;
/// row ordinal gaps preserve empty rows between rows that contain text. Entirely
/// empty trailing rows have no attributed content to reconstruct.
struct ToasttyMarkdownTableBuilder {
    struct Position {
        let tableID: Int
        let columns: [ToasttyMarkdownTable.ColumnAlignment]
        let row: Int
        let column: Int

        init?(_ intent: PresentationIntent?) {
            guard let intent else { return nil }
            var tableID: Int?
            var columns: [ToasttyMarkdownTable.ColumnAlignment] = []
            var row: Int?
            var column: Int?
            for component in intent.components {
                switch component.kind {
                case .table(let tableColumns):
                    tableID = component.identity
                    columns = tableColumns.map { column in
                        switch column.alignment {
                        case .left: .leading
                        case .center: .center
                        case .right: .trailing
                        @unknown default: .leading
                        }
                    }
                case .tableHeaderRow: row = 0
                case .tableRow(let ordinal): row = ordinal
                case .tableCell(let index): column = index
                default: break
                }
            }
            guard let tableID, let row, let column,
                  row >= 0, columns.indices.contains(column) else { return nil }
            self.tableID = tableID
            self.columns = columns
            self.row = row
            self.column = column
        }
    }

    let id: Int
    private(set) var table: ToasttyMarkdownTable

    init(position: Position) {
        id = position.tableID
        table = ToasttyMarkdownTable(columns: position.columns, rows: [])
    }

    mutating func append(_ content: AttributedString, at position: Position) {
        while table.rows.count <= position.row {
            table.rows.append(.init(
                id: table.rows.count,
                cells: Array(repeating: AttributedString(), count: table.columns.count)
            ))
        }
        table.rows[position.row].cells[position.column].append(content)
    }
}
