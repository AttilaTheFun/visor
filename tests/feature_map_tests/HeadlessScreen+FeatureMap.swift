// What the feature map's tests ask of a screen.

import IsomerHeadless

extension HeadlessScreen {
    func has(id: String) -> Bool { elements.contains { $0.id == id } }

    func has(label: String) -> Bool { elements.contains { $0.label == label } }

    /// Whether a session's row in Sessions, by its title, shows a mark
    /// labelled `label`: its element (`‹prefix›-‹id›`) where the driver
    /// lists a picture as one, else among the marks that follow its title
    /// in its texts, up to its preview (Isomer's lists a labelled picture
    /// as a text).
    func row(_ title: String, marked id: String, _ label: String) -> Bool {
        if element(id)?.label == label { return true }
        guard let start = texts.firstIndex(of: title) else { return false }
        let marks = texts[texts.index(after: start)...].prefix { Self.isMark($0) }
        return marks.contains(label)
    }

    /// The labels of a row's marks (SessionCardRow): its pin, its loop,
    /// its goal, and what is happening.
    static func isMark(_ text: String) -> Bool {
        ["Pinned", "Looping", "Working", "Waiting", "Waiting for your approval", "Asking you a question"].contains(text)
            || text.hasPrefix("Goal: ")
    }

    /// The texts of a session's row in Sessions, by its title, from its
    /// title to its preview.
    func rowTexts(_ title: String) -> [String] {
        guard let start = texts.firstIndex(of: title) else { return [] }
        let rest = texts[start...]
        let marks = rest.dropFirst().prefix { Self.isMark($0) }
        return Array(rest.prefix(marks.count + 2))
    }

    /// Whether `title` is the page's title: its first text on Isomer's
    /// runtime, its last on the iPhone (the navigation bar's, after the
    /// page's own).
    func titled(_ title: String) -> Bool { texts.first == title || texts.last == title }

    /// The screen's texts and elements, for a failure's message.
    var summary: String {
        "texts: \(texts.prefix(30)); elements: \(elements.map { "\($0.name) \($0.id ?? "") \($0.label.prefix(40))" })"
    }
}
