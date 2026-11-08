import VisorProtocol
import VisorServices

/// The Runners the person signed in to (RunnerAccount), any number: kept
/// with the device's settings (each session with its secrets), in the order
/// they were added.
@MainActor
public enum RunnerAccounts {
    static let key = "runner-accounts"
    public private(set) static var all: [RunnerAccount] = []

    static func account(_ id: String) -> RunnerAccount? { all.first { $0.id == id } }

    /// Read at launch; once.
    static func load() {
        guard all.isEmpty, let text = VisorHost.settings?.get(key: key), let list = parseJSON(text)?.array else { return }
        all = list.compactMap(RunnerAccount.Kept.init(json:)).map(RunnerAccount.init(kept:))
    }

    static func save() {
        VisorHost.settings?.set(key: key, value: JSONValue.array(all.map(\.kept.json)).encoded())
    }

    static func add(_ account: RunnerAccount) {
        all.removeAll { $0.id == account.id }
        all.append(account)
        save()
    }

    static func remove(_ id: String) {
        all.removeAll { $0.id == id }
        save()
    }

    /// A URL as an account keeps it: https unless it says otherwise, and no
    /// slash at its end.
    public static func normalized(_ url: String) -> String {
        // The standard library's own trimming: Visor on the web has none of
        // Foundation's.
        var url = String(url.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
        if !url.contains("://") { url = "https://" + url }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}
