import Foundation

enum Unzip {
    /// The zip's entries checked (none absolute, none with `..`, no
    /// symbolic links), unzipped into `scratch`, checked again, then moved
    /// into `destination`: how many files, how many bytes.
    static func extract(_ zip: String, into destination: String, scratch: String, unzip: String, git: Git) async throws -> (Int, Int) {
        let environment = ["PATH": git.searchPath, "LANG": "C", "LC_ALL": "C"]
        let names = try await Run.run(unzip, ["-Z1", zip], environment: environment, timeout: 120)
        guard names.status <= 1 else { throw ToolError.failed("the artifact is not a zip unzip can read: \(Redact.line(names.errorText))") }
        for name in names.output.split(whereSeparator: \.isNewline) {
            if name.hasPrefix("/") || name.contains("\\") || name.split(separator: "/").contains("..") {
                throw ToolError.refused("the artifact has an entry outside its folder (\(Redact.line(String(name), limit: 120))); not unzipped")
            }
        }
        let listing = try await Run.run(unzip, ["-Z", zip], environment: environment, timeout: 120)
        if listing.output.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("l") }) {
            throw ToolError.refused("the artifact has a symbolic link in it; not unzipped")
        }
        let files = FileManager.default
        try files.createDirectory(atPath: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = try await Run.run(unzip, ["-q", "-o", zip, "-d", scratch], environment: environment, timeout: 900)
        guard result.status <= 1 else { throw ToolError.failed("unzip failed: \(Redact.line(result.errorText))") }
        var count = 0, bytes = 0
        for item in files.enumerator(atPath: scratch)?.allObjects as? [String] ?? [] {
            let attributes = try files.attributesOfItem(atPath: scratch + "/" + item)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw ToolError.refused("the artifact has a symbolic link in it (\(item)); not unzipped") }
            if type == .typeRegular {
                count += 1
                bytes += (attributes[.size] as? Int) ?? 0
            }
        }
        try files.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for item in try files.contentsOfDirectory(atPath: scratch) {
            try files.moveItem(atPath: scratch + "/" + item, toPath: destination + "/" + item)
        }
        return (count, bytes)
    }
}
