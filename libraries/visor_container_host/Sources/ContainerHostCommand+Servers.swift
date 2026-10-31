import Foundation

/// The container host's interface, version 2 (docs/co-tenancy.md): a
/// container server's folder given to each command. `serve`, which runs
/// until it is ended, is the executable's own (applications/visor_container_host).
extension ContainerHostCommand {
    /// The commands that take a container server's folder.
    static let serverCommands: Set<String> = ["status", "credentials", "stop", "upgrade", "remove"]

    /// The host of the container server in `folder`, its secrets in a file
    /// there.
    public static func host(_ folder: URL, container: AppleContainer) throws -> ServerHost {
        let spec = try ServerSpec.read(folder)
        return ServerHost(server: ContainerServer(spec: spec, folder: folder, container: container, secrets: FileHostSecrets(folder: folder)))
    }

    static func serverAnswer(_ arguments: [String], input: Data, container: AppleContainer) -> Answer {
        guard let path = arguments.dropFirst().first else { return failure("\(arguments[0]) <the container server's folder>") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let host: ServerHost
        do {
            host = try Self.host(folder, container: container)
        } catch {
            return failure("No container server in \(path): \(error)", code: "notFound")
        }
        switch arguments[0] {
        case "status":
            let state = host.status()
            let json = (try? JSONSerialization.jsonObject(with: Data(state.json.utf8))) as? [String: Any] ?? [:]
            return Answer(status: 0, json: json)
        case "credentials":
            do {
                return Answer(status: 0, json: ["kept": try host.credentials(input)])
            } catch {
                return failure("\(error)")
            }
        case "stop":
            return host.server.stop() ? Answer(status: 0, json: ["stopped": host.server.spec.id]) : failure("\(host.server.spec.containerName) didn't stop")
        case "upgrade":
            if let problem = host.upgrade() { return failure(problem) }
            return Answer(status: 0, json: ["upgraded": host.server.spec.id, "image": host.server.spec.image])
        case "remove":
            host.server.remove(data: arguments.contains("--data"))
            return Answer(status: 0, json: ["removed": host.server.spec.id])
        default:
            return failure("no command \(arguments[0])", code: "unsupported")
        }
    }
}
