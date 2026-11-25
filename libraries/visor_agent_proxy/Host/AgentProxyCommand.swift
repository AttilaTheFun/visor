// `agent-proxy secret-set <name>` and `agent-proxy secret-remove <name>`:
// agent-proxy's secrets kept with the server's own (the keychain on a Mac,
// under the server's service; the secrets file elsewhere), from the command
// line. On Linux it's `visor-server agent-proxy …`; on a Mac, Visor's own
// executable, `/Applications/Visor.app/Contents/MacOS/Visor agent-proxy …`,
// so the item is the app's, read by the app and its agent-proxy job without
// asking.
//
// The value comes on standard input alone (never an argument, never the
// environment), its one line (the App's key: its PEM, every line), at most
// 16 KB; a terminal is refused, so a secret is piped in (`… | visor-server
// agent-proxy secret-set mcp/token`) and never typed where it's echoed or
// kept in a shell's history. The names:
//
//   github-token               the GitHub credential the gate attaches
//   claude/oauth-token         the Claude credential the Anthropic interceptor attaches
//   github-app/key             the GitHub App's private key, a PEM: with
//   github-app/id              its id, the App's installation tokens are
//   github-app/installation    attached instead (the installation optional)
//   mcp/token                  the sessions' token (X-Visor-Proxy)
//   mcp/<upstream>/<header>    an upstream's secret header
//
// each also with its `agent-proxy/` before it (as Shireworks named them).
// agent-proxy takes a new one within a minute, without a restart.

import Foundation
import VisorServer
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum AgentProxyCommand {
    public static let usage = """
        Usage: agent-proxy secret-set <name>      (the value on standard input, not a terminal)
               agent-proxy secret-remove <name>

          <name>   github-token, claude/oauth-token, github-app/key, github-app/id,
                   github-app/installation, mcp/token, or mcp/<upstream>/<header>
        """

    /// The most a secret may be.
    static let maxValue = 16 << 10

    /// What went wrong, said on standard error.
    struct Failure: Error {
        let message: String
        let status: Int32
    }

    /// Runs `arguments` (after `agent-proxy`) against `secrets`; what it
    /// returns is the process's exit status.
    public static func main(_ arguments: [String], secrets: any SecretStore,
                            input: FileHandle = .standardInput, inputIsTerminal: Bool = isatty(STDIN_FILENO) != 0) -> Int32 {
        do {
            let said = try run(arguments, secrets: secrets, input: input, inputIsTerminal: inputIsTerminal)
            print(said)
            return 0
        } catch let failure as Failure {
            FileHandle.standardError.write(Data("agent-proxy: \(failure.message)\n".utf8))
            return failure.status
        } catch {
            FileHandle.standardError.write(Data("agent-proxy: \(error)\n".utf8))
            return 1
        }
    }

    /// What it did, or why not.
    static func run(_ arguments: [String], secrets: any SecretStore, input: FileHandle, inputIsTerminal: Bool) throws -> String {
        guard arguments.count == 2, ["secret-set", "secret-remove"].contains(arguments[0]) else {
            throw Failure(message: "takes secret-set or secret-remove, and a name\n\n\(usage)", status: 2)
        }
        guard let name = AgentProxySettings.importableName(arguments[1]) else {
            throw Failure(message: "\(arguments[1]) isn't one of agent-proxy's secrets: github-token, claude/oauth-token, github-app/key, "
                          + "github-app/id, github-app/installation, mcp/token, or mcp/<upstream>/<header>", status: 2)
        }
        let key = AgentProxySettings.secretKey(name)
        if arguments[0] == "secret-remove" {
            secrets.set(key, nil)
            return "\(key) removed."
        }
        guard !inputIsTerminal else {
            throw Failure(message: "the value comes on standard input, piped in, never typed at a terminal", status: 2)
        }
        let data = input.readData(ofLength: maxValue + 1)
        guard data.count <= maxValue else { throw Failure(message: "a secret is at most \(maxValue >> 10) KB", status: 1) }
        let text = String(decoding: data, as: UTF8.self)
        let value: String
        if name == AgentProxySettings.githubAppKeyName {
            // A PEM, its lines kept.
            value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw Failure(message: "nothing on standard input", status: 1) }
            guard value.hasPrefix("-----BEGIN "), value.contains("PRIVATE KEY-----") else {
                throw Failure(message: "\(key) is the GitHub App's private key, a PEM (-----BEGIN RSA PRIVATE KEY-----)", status: 1)
            }
        } else {
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.count <= 1, let line = lines.first?.trimmingCharacters(in: .whitespaces), !line.isEmpty else {
                throw Failure(message: lines.isEmpty ? "nothing on standard input" : "a secret is one line", status: 1)
            }
            value = line
        }
        secrets.set(key, value)
        guard case .found(let kept) = secrets.lookup(key), kept == value else {
            throw Failure(message: "\(key) couldn't be kept", status: 1)
        }
        return "\(key) kept (\(value.utf8.count) bytes); agent-proxy takes it within a minute."
    }
}
