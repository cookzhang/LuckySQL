import AppKit
import SwiftUI

struct ResultGrid: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingCell: EditingCell?
    @State private var pendingDelete: Int?

    private var result: QueryResult { model.result }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Results").font(.headline)
                Spacer()
                Text("\(result.message) · \(result.elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 38)
            if result.columns.isEmpty {
                ContentUnavailableView("No result set", systemImage: "tablecells")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        row(result.columns, rowIndex: nil)
                        Divider()
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { index, values in
                            row(values, rowIndex: index)
                            Divider()
                        }
                    }
                }
            }
        }
        .sheet(item: $editingCell) { cell in
            CellEditor(cell: cell) { value in model.updateCell(row: cell.row, column: cell.column, value: value) }
        }
        .confirmationDialog("Delete this row?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Row", role: .destructive) {
                if let row = pendingDelete { model.deleteRow(row) }
                pendingDelete = nil
            }
        } message: { Text("This change is written to the database and cannot be undone.") }
    }

    private func row(_ values: [String], rowIndex: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(result.columns.indices), id: \.self) { index in
                let value = values.indices.contains(index) ? values[index] : ""
                Text(value)
                    .font(rowIndex == nil ? .system(size: 12, weight: .semibold) : .system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: 180, height: 30, alignment: .leading)
                    .background(rowIndex == nil ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .contextMenu {
                        Button("Copy") { copy(value) }
                        if let rowIndex {
                            Button("Edit…") { editingCell = EditingCell(row: rowIndex, column: index, value: value, name: result.columns[index]) }
                                .disabled(!model.canMutateSelectedTable)
                            Divider()
                            Button("Delete Row", role: .destructive) { pendingDelete = rowIndex }
                                .disabled(!model.canMutateSelectedTable)
                        }
                    }
                Divider()
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct EditingCell: Identifiable {
    let row: Int
    let column: Int
    let value: String
    let name: String
    var id: String { "\(row)-\(column)" }
}

private struct CellEditor: View {
    @Environment(\.dismiss) private var dismiss
    let cell: EditingCell
    let save: (String) -> Void
    @State private var value: String

    init(cell: EditingCell, save: @escaping (String) -> Void) {
        self.cell = cell
        self.save = save
        _value = State(initialValue: cell.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(cell.name)").font(.headline)
            TextField("Value", text: $value, axis: .vertical).lineLimit(3...10)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(value); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
    }
}
