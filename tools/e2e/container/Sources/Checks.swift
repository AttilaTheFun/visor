// What //tools/e2e/container found, each check said as it's made.

struct Checks {
    private(set) var passed: [String] = []
    private(set) var failed: [String] = []

    mutating func record(_ name: String, _ ok: Bool) {
        ContainerCheck.say((ok ? "ok: " : "FAILED: ") + name)
        if ok { passed.append(name) } else { failed.append(name) }
    }

    mutating func fail(_ name: String, _ why: String) { record("\(name): \(why)", false) }

    var summary: String {
        failed.isEmpty ? "all \(passed.count) checks passed" : "\(failed.count) of \(passed.count + failed.count) checks failed:\n  " + failed.joined(separator: "\n  ")
    }
}
