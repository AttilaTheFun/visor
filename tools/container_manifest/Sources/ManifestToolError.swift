/// Why container.json wasn't written: the arguments, or what they named.
struct ManifestToolError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
