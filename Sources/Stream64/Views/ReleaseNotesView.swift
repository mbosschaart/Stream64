import SwiftUI

/// Block-level Markdown for GitHub release notes. SwiftUI's `Text` only
/// understands inline Markdown (bold, code, links) and shows headings, list
/// markers and paragraph breaks literally, so blocks are split here and each
/// block's text is rendered with inline Markdown.
enum ReleaseNotesBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(number: String, text: String)
    case paragraph(String)
    case code(String)
    case rule

    static func parse(_ markdown: String) -> [ReleaseNotesBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if let open = codeLines {
                    blocks.append(.code(open.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = Self.heading(line) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if line.count >= 3, Set(line).isSubset(of: ["-", "*", "_"]),
               Set(line).count == 1 {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if let marker = ["- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                flushParagraph()
                let leading = rawLine.prefix { $0 == " " || $0 == "\t" }.count
                blocks.append(.bullet(
                    indent: min(leading / 2, 3),
                    text: String(line.dropFirst(marker.count))))
                continue
            }
            if let dot = line.firstIndex(of: "."),
               line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                blocks.append(.numbered(
                    number: String(line[..<dot]),
                    text: String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            // Continuation of a list item wrapped onto the next line.
            if paragraph.isEmpty, case .bullet(let indent, let text)? = blocks.last,
               rawLine.first == " " {
                blocks[blocks.count - 1] = .bullet(indent: indent, text: text + " " + line)
                continue
            }
            paragraph.append(line)
        }
        if let open = codeLines {
            blocks.append(.code(open.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> ReleaseNotesBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes),
              line.dropFirst(hashes).first == " " else { return nil }
        return .heading(
            level: hashes,
            text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }
}

struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        let blocks = ReleaseNotesBlock.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: ReleaseNotesBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level <= 2 ? .headline : .body.weight(.semibold))
                .padding(.top, 4)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                inline(text)
            }
        case .paragraph(let text):
            inline(text)
        case .code(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
