/// A value bound to a statement's `?`.
enum SQLiteValue {
    case int(Int)
    case text(String)
    case null

    static func optional(_ text: String?) -> SQLiteValue { text.map(SQLiteValue.text) ?? .null }
}
