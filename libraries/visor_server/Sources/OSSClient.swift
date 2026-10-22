import Foundation

/// An oss server (OS Server, AttilaTheFun/oss), as the Visor server drives
/// it over its HTTP API, with its token: its agent sessions (a container
/// each, made without an agent of oss's own), the files in a session's
/// home (`/root`), and the processes run in it, their input given and
/// their output read on from where it was left. Through the platform's
/// own HTTP client.
struct OSSClient: Sendable {
    /// Its API's address ("http://host:7480").
    let server: String
    let token: String

    /// What oss said when it refused, or that it could not be reached.
    struct Failure: Error, LocalizedError {
        let words: String
        var errorDescription: String? { words }
    }

    /// Some of a process's output, from an offset: where to read on from,
    /// and how the process stands ("running", "exited" with `status`, or
    /// "lost": its container stopped under it).
    struct Output: Sendable {
        var data: Data
        var next: Int
        var state: String
        var status: Int?
    }

    /// The longest a read is held open for more to come.
    static let longestWait = 30

    // MARK: Sessions

    /// A session made, its container up and idle (no agent of oss's own):
    /// labelled with Visor's session, from `image` (oss's own when nil).
    /// Its id. (Its repository is cloned by `clone`, whose end is known:
    /// oss's own clone, given a repository here, runs on its own.)
    func makeSession(agent: String, labels: [String: String], image: String?) async throws -> String {
        var body: [String: Any] = ["agent": agent, "launch": false, "holder": "visor", "labels": labels]
        if let image, !image.isEmpty { body["image"] = image }
        let answer = try await call("POST", "/v1/agents", json: body, timeout: 300)
        guard let id = Self.object(answer.body)?["id"] as? String else { throw Failure(words: "oss made no session") }
        return id
    }

    /// The session and its container gone, with its home.
    func removeSession(_ session: String) async throws {
        _ = try await call("DELETE", "/v1/agents/\(session)")
    }

    // MARK: Files

    /// A file written in the session's home (`path` from `/root`).
    func writeFile(_ session: String, path: String, data: Data) async throws {
        _ = try await call("PUT", "/v1/agents/\(session)/files/\(Self.escaped(path))", body: data)
    }

    /// Some of a file: its bytes from an offset and its length now — or,
    /// from an oss that reads no offsets, the whole file (`whole`).
    struct FilePart: Sendable {
        var data: Data
        var size: Int
        var whole: Bool
    }

    /// A file's bytes from `from`, held open up to `wait` seconds until it
    /// grows past it, and its length now; nil while there is no such file.
    func readFile(_ session: String, path: String, from: Int, wait: Int) async throws -> FilePart? {
        let answer = try await request("GET", "/v1/agents/\(session)/files/\(Self.escaped(path))?from=\(from)&wait=\(wait)",
                                       timeout: Double(wait + 15))
        if answer.status == 404 { return nil }
        try Self.check(answer)
        guard let size = answer.headers["oss-size"].flatMap(Int.init) else { return FilePart(data: answer.body, size: answer.body.count, whole: true) }
        return FilePart(data: answer.body, size: size, whole: false)
    }

    /// A repository cloned into `folder` in the session's container, git's
    /// own end awaited (ten minutes at most); why not, when it was not.
    func clone(_ session: String, url: String, into folder: String) async throws {
        let process = try await startProcess(session, command: ["git", "clone", "-q", url, folder], environment: [:], directory: "/root")
        var errors = Data()
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            let got = try await output(session, process: process.id, stream: "err", from: errors.count, wait: Self.longestWait)
            errors.append(got.data)
            guard got.state == "running" || !got.data.isEmpty else {
                if got.status == 0 { return }
                let said = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(words: "Cloning \(url) failed" + (said.isEmpty ? "." : ": \(said)"))
            }
        }
        try? await signal(session, process: process.id, "KILL")
        throw Failure(words: "Cloning \(url) took more than ten minutes.")
    }

    /// What a short command prints in the session's container, once it has
    /// run (a minute at most).
    func run(_ session: String, _ command: [String]) async throws -> String {
        let process = try await startProcess(session, command: command, environment: [:], directory: "/root")
        var printed = Data()
        var offset = 0
        for _ in 0..<4 {
            let got = try await output(session, process: process.id, stream: "out", from: offset, wait: 15)
            printed.append(got.data)
            offset = got.next
            if got.state != "running", got.data.isEmpty { break }
        }
        return String(decoding: printed, as: UTF8.self)
    }

    // MARK: Processes

    /// A command started in the session's container, in `directory`, with
    /// `environment` for it alone (oss keeps it nowhere): its id and its
    /// process id there.
    func startProcess(_ session: String, command: [String], environment: [String: String], directory: String) async throws -> (id: String, pid: Int32) {
        let answer = try await call("POST", "/v1/agents/\(session)/processes",
                                    json: ["command": command, "environment": environment, "directory": directory])
        guard let process = Self.object(answer.body), let id = process["id"] as? String else { throw Failure(words: "oss started no process") }
        return (id, Int32((process["pid"] as? Int) ?? 0))
    }

    /// Bytes for the process's input, in order; with `close`, its end.
    func input(_ session: String, process: String, data: Data, close: Bool = false) async throws {
        _ = try await call("POST", "/v1/agents/\(session)/processes/\(process)/input" + (close ? "?close=1" : ""), body: data)
    }

    /// Its output ("out") or errors ("err") from `from`, held open up to
    /// `wait` seconds for more.
    func output(_ session: String, process: String, stream: String, from: Int, wait: Int) async throws -> Output {
        let answer = try await call("GET", "/v1/agents/\(session)/processes/\(process)/output?stream=\(stream)&from=\(from)&wait=\(wait)",
                                    timeout: Double(wait + 15))
        return Output(data: answer.body, next: answer.headers["oss-offset"].flatMap(Int.init) ?? (from + answer.body.count),
                      state: answer.headers["oss-state"] ?? "running", status: answer.headers["oss-status"].flatMap(Int.init))
    }

    /// A signal to the process: "TERM", "KILL", "INT", "HUP".
    func signal(_ session: String, process: String, _ signal: String) async throws {
        _ = try await call("POST", "/v1/agents/\(session)/processes/\(process)/signal?signal=\(signal)", body: Data())
    }

    // MARK: Asking

    private func call(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data = Data(), timeout: Double = 30)
        async throws -> OutgoingRequest.Answer {
        let data = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? body
        let answer = try await request(method, path, body: data, json: json != nil, timeout: timeout)
        try Self.check(answer)
        return answer
    }

    private func request(_ method: String, _ path: String, body: Data = Data(), json: Bool = false, timeout: Double) async throws
        -> OutgoingRequest.Answer {
        var headers = ["Authorization": "Bearer " + token]
        if json { headers["Content-Type"] = "application/json" }
        do {
            return try await ServerPlatform.current.fetching.fetch(OutgoingRequest(url: server + path, method: method, headers: headers,
                                                                                  body: body, timeout: timeout))
        } catch {
            throw Failure(words: "oss at \(server) can't be reached: \(error.localizedDescription)")
        }
    }

    private static func check(_ answer: OutgoingRequest.Answer) throws {
        guard !(200..<300).contains(answer.status) else { return }
        let said = (object(answer.body)?["error"] as? String) ?? String(decoding: answer.body.prefix(300), as: UTF8.self)
        throw Failure(words: "oss: \(said.isEmpty ? "status \(answer.status)" : said)")
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A path in a session's home, each part escaped for the URL.
    static func escaped(_ path: String) -> String {
        path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
    }
}
