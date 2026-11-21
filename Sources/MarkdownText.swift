import SwiftUI

/// Renders the backend's page about a person as list sections.
///
/// The page is a small subset of Markdown: a `#` title, `##` headings, `- `
/// bullets, a `> ` quote, an `*emphasised*` line, with **bold** and `code`
/// inline. Each `##` heading starts a section and every block under it is a
/// row. The `#` title is dropped, because the navigation bar already shows
/// the name.
struct MarkdownSections: View {
    let md: String
    /// Leaves out the emphasised line (their role and company) when the page
    /// already shows it in a header.
    var skipsSubtitle = false

    private struct Row: Identifiable {
        let id: Int
        let text: String
        var secondary = false
        /// When a History line happened, if it began with a timestamp.
        var date: Date?
    }

    /// Splits "`2026-11-21 10:38:07` what happened" into the date and the rest.
    private static func dated(_ text: String) -> (Date, String)? {
        guard text.hasPrefix("`"),
              let close = text.dropFirst().firstIndex(of: "`")
        else { return nil }
        let stamp = String(text[text.index(after: text.startIndex)..<close])
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            parser.dateFormat = format
            if let date = parser.date(from: stamp) {
                let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
                return (date, rest)
            }
        }
        return nil
    }

    private struct Group: Identifiable {
        let id: Int
        var title: String?
        var rows: [Row] = []
    }

    private var groups: [Group] {
        var result = [Group(id: 0)]
        var rowID = 0
        for rawLine in md.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" || line == "***" || line.hasPrefix("# ") {
                continue
            }
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                result.append(Group(id: result.count, title: title))
                continue
            }

            var row = Row(id: rowID, text: line)
            rowID += 1
            if line.hasPrefix("> ") || line.hasPrefix("- ") || line.hasPrefix("* ") {
                let text = String(line.dropFirst(2))
                if let (date, rest) = Self.dated(text) {
                    row = Row(id: row.id, text: rest, date: date)
                } else {
                    row = Row(id: row.id, text: text)
                }
            } else if line.hasPrefix("*"), line.hasSuffix("*"), line.count > 2, !line.hasPrefix("**") {
                // A line that is emphasised as a whole: their organisation.
                if skipsSubtitle { continue }
                row = Row(id: row.id, text: String(line.dropFirst().dropLast()), secondary: true)
            }
            result[result.count - 1].rows.append(row)
        }
        return result.filter { !$0.rows.isEmpty }
    }

    var body: some View {
        ForEach(groups) { group in
            Section {
                ForEach(group.rows) { row in
                    if let date = row.date {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inline(row.text))
                            Text(date.formatted(.relative(presentation: .named)))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(inline(row.text))
                            .foregroundStyle(row.secondary ? .secondary : .primary)
                    }
                }
            } header: {
                if let title = group.title {
                    Text(title)
                }
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
