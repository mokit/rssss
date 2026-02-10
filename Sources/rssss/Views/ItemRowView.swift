import SwiftUI

struct ItemRowView: View {
    let item: FeedItem
    let isSelected: Bool
    let onView: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayTitle)
                .font(.title3)
                .foregroundStyle(item.isRead ? .secondary : .primary)
                .lineLimit(2)

            if let dateText = relativeDateText() {
                Text(dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !item.displaySummary.isEmpty {
                Text(item.displaySummary)
                    .font(.body)
                    .foregroundStyle(item.isRead ? .tertiary : .secondary)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("View") {
                    onView()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }

    private func relativeDateText() -> String? {
        guard let date = item.pubDate else { return nil }
        return RelativeDateFormatter.shared.localizedString(for: date, relativeTo: Date())
    }

}

enum RelativeDateFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
