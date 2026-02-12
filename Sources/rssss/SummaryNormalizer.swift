import Foundation

enum SummaryNormalizer {
    static func normalized(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard shouldParseHTML(trimmed) else {
            return trimmed
        }

        guard let data = trimmed.data(using: .utf8) else {
            return trimmed
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        let plain = attributed?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let plain, !plain.isEmpty else {
            return trimmed
        }
        return plain
    }

    private static func shouldParseHTML(_ text: String) -> Bool {
        text.contains("<") && text.contains(">")
    }
}
