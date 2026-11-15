// What the feature map's tests ask of a screen.

import IsomerHeadless

extension HeadlessScreen {
    func has(id: String) -> Bool { elements.contains { $0.id == id } }

    func has(label: String) -> Bool { elements.contains { $0.label == label } }

    /// The screen's texts and elements, for a failure's message.
    var summary: String {
        "texts: \(texts.prefix(30)); elements: \(elements.map { "\($0.name) \($0.id ?? "") \($0.label.prefix(40))" })"
    }
}
