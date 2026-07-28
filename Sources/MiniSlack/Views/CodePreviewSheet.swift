import SwiftUI

struct CodePreviewSheet: View {
    let filename: String
    let detail: String
    let document: CodePreviewDocument
    let openInQuickLook: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(document.lines.enumerated()), id: \.offset) {
                        index, tokens in
                        CodePreviewLine(number: index + 1, tokens: tokens)
                    }

                    if document.isTruncated {
                        Text("Preview truncated — open the file to see the rest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 480, idealWidth: 760, minHeight: 320, idealHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Quick Look", systemImage: "eye") {
                dismiss()
                openInQuickLook()
            }
            .help("Open in Quick Look")
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.bar)
    }

    private var subtitle: String {
        // `detail` already names the file type, so the syntax name would only
        // repeat it.
        let lineText = document.lines.count == 1
            ? "1 line"
            : "\(document.lines.count) lines"
        return [detail.isEmpty ? document.syntaxName : detail, lineText]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct CodePreviewLine: View {
    let number: Int
    let tokens: [CodePreviewToken]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)

            Text(styled)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 15, alignment: .leading)
    }

    private var styled: AttributedString {
        var result = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            piece.foregroundColor = token.kind.color
            result.append(piece)
        }
        // An empty line still needs height.
        return result.characters.isEmpty ? AttributedString(" ") : result
    }
}

private extension CodePreviewTokenKind {
    var color: Color {
        switch self {
        case .plain:
            Color(nsColor: .labelColor)
        case .comment:
            Color(nsColor: .secondaryLabelColor)
        case .string:
            Color(nsColor: .systemRed)
        case .number:
            Color(nsColor: .systemBlue)
        case .keyword:
            Color(nsColor: .systemPurple)
        }
    }
}
