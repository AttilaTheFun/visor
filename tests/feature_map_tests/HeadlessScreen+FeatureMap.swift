// What the feature map's tests ask of a screen.

import IsomerHeadless

extension HeadlessScreen {
    func has(id: String) -> Bool { elements.contains { $0.id == id } }

    func has(label: String) -> Bool { elements.contains { $0.label == label } }

    /// Whether a session's row in Sessions, by its title, shows a mark
    /// labelled `label`: its element (`‹prefix›-‹id›`) where the driver
    /// lists a picture as one, else among the row's texts, from its title
    /// to its folder (Isomer's lists a labelled picture as a text).
    func row(_ title: String, marked id: String, _ label: String) -> Bool {
        if element(id)?.label == label { return true }
        guard let start = texts.firstIndex(of: title) else { return false }
        let rest = texts[texts.index(after: start)...]
        let end = rest.firstIndex { $0.hasPrefix("/") } ?? rest.endIndex
        return rest[..<end].contains(label)
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
