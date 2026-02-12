import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var logStore: AppLogStore

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Text("\(logStore.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    logStore.clear()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(logStore.entries) { entry in
                Text("[\(Self.formatter.string(from: entry.timestamp))] \(entry.message)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 760, minHeight: 420)
    }
}
