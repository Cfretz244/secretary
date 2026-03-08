import SwiftUI

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .codeBlock(let language):
                    codeBlockView(content: block.content, language: language)
                case .heading(let level):
                    headingView(content: block.content, level: level)
                case .listItem(let bullet):
                    listItemView(content: block.content, bullet: bullet)
                case .paragraph:
                    paragraphView(content: block.content)
                }
            }
        }
    }

    // MARK: - Block renderers

    @ViewBuilder
    private func codeBlockView(content: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, language != nil ? 6 : 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func headingView(content: String, level: Int) -> some View {
        Text(inlineMarkdown(content))
            .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func listItemView(content: String, bullet: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(bullet)
                .foregroundStyle(.secondary)
                .frame(width: bullet.count > 1 ? 24 : 12, alignment: .trailing)
            Text(inlineMarkdown(content))
                .textSelection(.enabled)
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func paragraphView(content: String) -> some View {
        Text(inlineMarkdown(content))
            .textSelection(.enabled)
    }

    // MARK: - Inline markdown

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    }

    // MARK: - Parser

    private struct MarkdownBlock {
        enum Kind {
            case paragraph
            case codeBlock(language: String?)
            case heading(level: Int)
            case listItem(bullet: String)
        }
        let kind: Kind
        let content: String
    }

    private var blocks: [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            result.append(MarkdownBlock(kind: .paragraph, content: paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }

        while i < lines.count {
            let line = lines[i]

            // Code block
            if line.hasPrefix("```") {
                flushParagraph()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                // Skip closing ```
                if i < lines.count { i += 1 }
                result.append(MarkdownBlock(
                    kind: .codeBlock(language: lang.isEmpty ? nil : lang),
                    content: codeLines.joined(separator: "\n")
                ))
                continue
            }

            // Heading
            if let headingMatch = parseHeading(line) {
                flushParagraph()
                result.append(MarkdownBlock(kind: .heading(level: headingMatch.level), content: headingMatch.content))
                i += 1
                continue
            }

            // List item (unordered)
            if line.starts(with: "- ") || line.starts(with: "* ") {
                flushParagraph()
                let content = String(line.dropFirst(2))
                result.append(MarkdownBlock(kind: .listItem(bullet: "\u{2022}"), content: content))
                i += 1
                continue
            }

            // List item (ordered)
            if let orderedMatch = parseOrderedListItem(line) {
                flushParagraph()
                result.append(MarkdownBlock(kind: .listItem(bullet: orderedMatch.number), content: orderedMatch.content))
                i += 1
                continue
            }

            // Empty line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Regular text → paragraph
            paragraphLines.append(line)
            i += 1
        }

        flushParagraph()
        return result
    }

    private struct HeadingMatch {
        let level: Int
        let content: String
    }

    private func parseHeading(_ line: String) -> HeadingMatch? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 3 && line.count > level && line[line.index(line.startIndex, offsetBy: level)] == " " else {
            return nil
        }
        let content = String(line.dropFirst(level + 1))
        return HeadingMatch(level: level, content: content)
    }

    private struct OrderedListMatch {
        let number: String
        let content: String
    }

    private func parseOrderedListItem(_ line: String) -> OrderedListMatch? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let content = String(line[line.index(after: afterDot)...])
        return OrderedListMatch(number: "\(prefix).", content: content)
    }
}
