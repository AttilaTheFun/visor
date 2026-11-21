// A step of //tools/e2e/container that couldn't be taken.

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
