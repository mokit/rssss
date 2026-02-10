import SwiftUI

struct AddFeedSheet: View {
    @State private var urlString = ""
    @State private var isValid = true

    let onAdd: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Feed")
                .font(.title2)

            TextField("https://example.com/feed.xml", text: $urlString)
                .textFieldStyle(.roundedBorder)

            if !isValid {
                Text("Enter a valid HTTPS URL (for example: https://example.com/feed.xml).")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                Button("Add") {
                    if validate(urlString) {
                        onAdd(urlString)
                    } else {
                        isValid = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: urlString) { _, _ in
            isValid = true
        }
    }

    private func validate(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return false }
        return url.scheme?.lowercased() == "https"
    }
}
