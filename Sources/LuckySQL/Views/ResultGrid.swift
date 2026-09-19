import SwiftUI

struct ResultGrid: View {
    let result: QueryResult

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
                        row(result.columns, header: true)
                        Divider()
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { _, values in
                            row(values, header: false)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func row(_ values: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(result.columns.indices), id: \.self) { index in
                Text(values.indices.contains(index) ? values[index] : "")
                    .font(header ? .system(.caption, design: .default).bold() : .system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: 180, height: 28, alignment: .leading)
                    .background(header ? Color(nsColor: .controlBackgroundColor) : .clear)
                Divider()
            }
        }
    }
}
