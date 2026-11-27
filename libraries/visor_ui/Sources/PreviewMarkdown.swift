import SwiftUI

/// A message's first lines as a row in Sessions shows them (Logan, 26 Nov
/// 2026: not its raw markdown): **bold** and *italic* styled, `code` in
/// the monospaced font, a link by its words (never one to follow, in a
/// row), and what a two-line preview can't show of the blocks stripped to
/// their words — headings' `#`s, list markers, quotes' `>`, code fences,
/// rules and blank lines. In Swift alone, not Foundation's markdown, so it
/// reads the same on Isomer (the web, Android, Linux) as on Apple's
/// platforms. A marker with nothing to close it stays as it was written.
enum PreviewMarkdown {
    /// A piece of the preview and its style.
    struct Span: Equatable {
        var text: String
        var bold = false
        var italic = false
        var code = false
    }

    /// The preview as styled text: its plain colors, whatever the row
    /// gives it.
    static func text(_ markdown: String) -> Text {
        let pieces = spans(markdown)
        // One plain piece is one plain text, as a row had it before.
        if pieces.count == 1, let only = pieces.first, !only.bold, !only.italic, !only.code { return Text(only.text) }
        var result: Text?
        for span in pieces {
            var piece = Text(span.text)
            // Semibold, as AgentUI's markdown draws **strong**.
            if span.bold { piece = piece.fontWeight(.semibold) }
            if span.italic { piece = piece.italic() }
            if span.code { piece = piece.monospaced() }
            result = result.map { $0 + piece } ?? piece
        }
        return result ?? Text("")
    }

    /// Its words alone, as they show.
    static func plain(_ markdown: String) -> String { spans(markdown).map(\.text).joined() }

    /// The preview's pieces: its lines with what their blocks begin with
    /// taken off (a code block's lines kept whole, as code), joined by a
    /// line's end, each read for its inline markdown.
    static func spans(_ markdown: String) -> [Span] {
        var out: [Span] = []
        var fenced = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = String(line.drop(while: \.isBlank).reversed().drop(while: \.isBlank).reversed())
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenced.toggle()
                continue
            }
            let pieces: [Span]
            if fenced {
                pieces = trimmed.isEmpty ? [] : [Span(text: line, code: true)]
            } else {
                let words = blockStripped(trimmed)
                pieces = words.isEmpty ? [] : inline(words)
            }
            guard !pieces.isEmpty else { continue }
            if !out.isEmpty { append(Span(text: "\n"), to: &out) }
            for piece in pieces { append(piece, to: &out) }
        }
        return out
    }

    /// A line without what its block begins with: a quote's `>`s, a
    /// heading's `#`s (and those closing it), a list's marker and a task's
    /// box; a rule is nothing.
    static func blockStripped(_ line: String) -> String {
        var rest = Substring(line)
        // A quote, however deep.
        while rest.hasPrefix(">") { rest = rest.dropFirst().drop(while: \.isBlank) }
        // A rule: three or more of one of -, * or _, and nothing else.
        let marks = rest.filter { $0 != " " }
        if marks.count >= 3, let first = marks.first, "-*_".contains(first), marks.allSatisfy({ $0 == first }) { return "" }
        // A heading.
        let hashes = rest.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), rest.dropFirst(hashes).first == " " || rest.count == hashes {
            rest = rest.dropFirst(hashes).drop(while: \.isBlank)
            // Its closing `#`s, after a space (`# C#` keeps its own).
            let closing = rest.reversed().prefix(while: { $0 == "#" }).count
            if closing > 0, closing == rest.count || rest.dropLast(closing).last == " " { rest = rest.dropLast(closing) }
            while rest.last == " " { rest = rest.dropLast() }
        }
        // A list's item: a bullet, or a number and its dot or parenthesis.
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            rest = rest.dropFirst(2).drop(while: \.isBlank)
        } else {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber }).count
            if (1...9).contains(digits), let mark = rest.dropFirst(digits).first, mark == "." || mark == ")",
               rest.dropFirst(digits + 1).first == " " {
                rest = rest.dropFirst(digits + 2).drop(while: \.isBlank)
            }
        }
        // A task's box.
        for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) { rest = rest.dropFirst(box.count) }
        return String(rest)
    }

    /// A line's inline markdown: code, links and images by their words,
    /// strong and emphasis, struck words as they are, and escapes.
    static func inline(_ line: String, bold outerBold: Bool = false, italic outerItalic: Bool = false) -> [Span] {
        let chars = Array(line)
        var out: [Span] = []
        var bold = outerBold, italic = outerItalic, struck = false
        var i = 0
        func add(_ text: String, code: Bool = false) { append(Span(text: text, bold: bold, italic: italic, code: code), to: &out) }
        /// Whether `marker` closes later in the line, after a character that
        /// isn't a space.
        func closes(_ marker: [Character], after start: Int) -> Bool {
            var j = start
            while j + marker.count <= chars.count {
                if Array(chars[j..<(j + marker.count)]) == marker, j > start, !chars[j - 1].isWhitespace { return true }
                j += 1
            }
            return false
        }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let previous: Character? = i > 0 ? chars[i - 1] : nil
            // An escaped mark is the mark.
            if c == "\\", let next, "\\`*_{}[]()#+-.!~>|".contains(next) {
                add(String(next))
                i += 2
                continue
            }
            // Code: up to as many backticks as opened it.
            if c == "`" {
                let run = chars[i...].prefix(while: { $0 == "`" }).count
                let fence = [Character](repeating: "`", count: run)
                var j = i + run, end: Int?
                while j + run <= chars.count {
                    if Array(chars[j..<(j + run)]) == fence, j + run == chars.count || chars[j + run] != "`" { end = j; break }
                    j += 1
                }
                if let end {
                    var code = String(chars[(i + run)..<end])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 1 { code = String(code.dropFirst().dropLast()) }
                    add(code, code: true)
                    i = end + run
                    continue
                }
                add(String(fence))
                i += run
                continue
            }
            // A link or an image: its words, read for their own markdown.
            var opens: Int?
            if c == "[" { opens = i } else if c == "!", next == "[" { opens = i + 1 }
            if let opens, let close = chars[opens...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(",
               let end = chars[(close + 1)...].firstIndex(of: ")") {
                for span in inline(String(chars[(opens + 1)..<close]), bold: bold, italic: italic) { append(span, to: &out) }
                i = end + 1
                continue
            }
            // Struck words show as words.
            if c == "~", next == "~" {
                if struck || closes(["~", "~"], after: i + 2) {
                    struck.toggle()
                    i += 2
                    continue
                }
            }
            if c == "*" || c == "_" {
                // An underscore inside a word (snake_case) is the word's.
                let inWord = c == "_" && (previous.map { $0.isLetter || $0.isNumber } ?? false)
                    && (next.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false)
                if !inWord {
                    if next == c {
                        if bold, !(previous?.isWhitespace ?? true) {
                            bold = false
                            i += 2
                            continue
                        }
                        if !bold, let after = i + 2 < chars.count ? chars[i + 2] : nil, !after.isWhitespace, closes([c, c], after: i + 2) {
                            bold = true
                            i += 2
                            continue
                        }
                    } else {
                        if italic, !(previous?.isWhitespace ?? true) {
                            italic = false
                            i += 1
                            continue
                        }
                        if !italic, let next, !next.isWhitespace, closes([c], after: i + 1) {
                            italic = true
                            i += 1
                            continue
                        }
                    }
                }
            }
            add(String(c))
            i += 1
        }
        return out
    }

    /// A piece after the others: joined to the last when it is styled the
    /// same.
    private static func append(_ span: Span, to spans: inout [Span]) {
        guard !span.text.isEmpty else { return }
        if let last = spans.last, last.bold == span.bold, last.italic == span.italic, last.code == span.code {
            spans[spans.count - 1].text += span.text
        } else {
            spans.append(span)
        }
    }
}

private extension Character {
    /// A space or a tab: what a line's markdown is indented and spaced by.
    var isBlank: Bool { self == " " || self == "\t" }
}
