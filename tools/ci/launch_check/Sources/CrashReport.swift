import Foundation

/// A crash report macOS wrote (~/Library/Logs/DiagnosticReports, `.ips`):
/// its first line a JSON header, the rest one JSON body. What a launch
/// check prints of it: the exception, the `asi` (the messages a library
/// left, Swift's fatal errors among them) and the faulting thread's top
/// frames. Read leniently, field by field: a report missing one still
/// says the rest.
struct CrashReport {
    let url: URL
    let header: [String: Any]
    let body: [String: Any]

    /// The newest `<prefix>-*.ips` in the user's DiagnosticReports written
    /// at or after `since`, if any.
    static func newest(named prefix: String, since: Date) -> URL? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix + "-") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date >= since else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }?.0
    }

    init(contentsOf url: URL) throws {
        guard let data = FileManager.default.contents(atPath: url.path),
              let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any] else {
            throw LaunchCheckError.setup("\(url.path) isn't a crash report (a JSON header line, then a JSON body)")
        }
        self.url = url
        self.header = header
        self.body = body
    }

    /// The report as the check prints it, its faulting thread's top
    /// `limit` frames.
    func summary(frames limit: Int = 15) -> String {
        func text(_ value: Any?) -> String? {
            switch value {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        var lines = ["Crash report: \(url.path)"]
        let app = ["app_name", "app_version", "build_version"].compactMap { text(header[$0]) }
        lines.append("  App: \(app.joined(separator: " ")); \(text(header["os_version"]) ?? "macOS ?"); \(text(header["timestamp"]) ?? "")")
        if let exception = body["exception"] as? [String: Any] {
            let parts = ["type", "signal", "codes", "subtype"].compactMap { text(exception[$0]) }
            lines.append("  Exception: \(parts.joined(separator: ", "))")
        }
        if let termination = body["termination"] as? [String: Any], let indicator = text(termination["indicator"]) {
            lines.append("  Termination: \(indicator)")
        }
        if let asi = body["asi"] as? [String: Any] {
            for (image, value) in asi.sorted(by: { $0.key < $1.key }) {
                lines.append("  asi (\(image)):")
                let messages = (value as? [Any])?.compactMap(text) ?? [text(value)].compactMap { $0 }
                for message in messages {
                    lines += message.split(separator: "\n").map { "    \($0)" }
                }
            }
        } else {
            lines.append("  asi: none")
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let named = (body["faultingThread"] as? NSNumber)?.intValue
        guard let faulting = named ?? threads.firstIndex(where: { ($0["triggered"] as? Bool) == true }),
              threads.indices.contains(faulting) else {
            lines.append("  (no faulting thread named)")
            return lines.joined(separator: "\n")
        }
        let thread = threads[faulting]
        let label = [text(thread["name"]), text(thread["queue"]).map { "queue \($0)" }].compactMap { $0 }.joined(separator: ", ")
        lines.append("  Faulting thread \(faulting)\(label.isEmpty ? "" : " (\(label))"):")
        let images = body["usedImages"] as? [[String: Any]] ?? []
        for (index, frame) in (thread["frames"] as? [[String: Any]] ?? []).prefix(limit).enumerated() {
            let imageIndex = (frame["imageIndex"] as? NSNumber)?.intValue
            let image = imageIndex.flatMap { images.indices.contains($0) ? text(images[$0]["name"]) : nil } ?? "???"
            let symbol: String
            if let name = text(frame["symbol"]) {
                symbol = "\(name) + \(text(frame["symbolLocation"]) ?? "0")"
            } else if let offset = (frame["imageOffset"] as? NSNumber)?.intValue {
                symbol = "0x\(String(offset, radix: 16))"
            } else {
                symbol = "?"
            }
            let number = String(index).padding(toLength: 4, withPad: " ", startingAt: 0)
            lines.append("    \(number)\(image.padding(toLength: 34, withPad: " ", startingAt: 0)) \(symbol)")
        }
        return lines.joined(separator: "\n")
    }
}
