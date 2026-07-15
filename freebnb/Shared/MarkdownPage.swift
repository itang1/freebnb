import SwiftUI

struct MarkdownPage: View {
    let fileName: String
    let title: String
    @State private var content: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if content.isEmpty {
                    Text("Unable to load document")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ForEach(parseMarkdown(content), id: \.self) { block in
                        renderBlock(block)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadContent()
        }
    }

    private func loadContent() {
        if let url = Bundle.main.url(forResource: fileName, withExtension: "md"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            content = text
        }
    }

    private func parseMarkdown(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    @ViewBuilder
    private func renderBlock(_ line: String) -> some View {
        if line.isEmpty {
            Spacer().frame(height: 4)
        } else if line.hasPrefix("# ") {
            Text(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top, 12)
        } else if line.hasPrefix("## ") {
            Text(line.dropFirst(3).trimmingCharacters(in: .whitespaces))
                .font(.headline)
                .fontWeight(.semibold)
                .padding(.top, 8)
        } else if line.hasPrefix("### ") {
            Text(line.dropFirst(4).trimmingCharacters(in: .whitespaces))
                .font(.subheadline)
                .fontWeight(.semibold)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.system(.body, design: .monospaced))
                Text(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        } else {
            Text(line)
                .lineSpacing(2)
        }
    }
}

#Preview {
    NavigationStack {
        MarkdownPage(fileName: "privacy-policy", title: "Privacy Policy")
    }
}
