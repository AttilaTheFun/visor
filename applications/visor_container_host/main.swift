import Foundation
import Synchronization
import VisorContainerHost

// visor-container-host <operation> [arguments]: version 2's commands take
// a container server's folder (docs/co-tenancy.md); version 1's
// (docs/container-host.md) stay until Visor Server moves to them.
let arguments = Array(CommandLine.arguments.dropFirst())
let container = AppleContainer()

func answer(_ answer: ContainerHostCommand.Answer) -> Never {
    print(answer.text)
    exit(answer.status)
}

if arguments.first == "exec" {
    // exec becomes `container exec`: its input, output, signals and status
    // the program's own.
    guard let run = ContainerHostCommand.execArguments(Array(arguments.dropFirst())) else {
        answer(.init(status: 2, json: ["error": "exec <id> [--workdir=DIR] [--env-file=FILE] [--interactive] -- program…"]))
    }
    guard ContainerHostCommand.started(run.id, container: container) else {
        answer(.init(status: 1, json: ["error": "There is no container \(run.id)", "code": "notFound"]))
    }
    let argv = ([container.tool] + run.arguments).map { strdup($0) } + [nil]
    execv(container.tool, argv)
    answer(.init(status: 127, json: ["error": "Apple's container (\(container.tool)) couldn't be run"]))
}

// serve: the container server kept up and its clients' connections passed
// on, until ended (TERM, INT, HUP: launchd stopping it, an update); the
// container and its server left running.
let stopped = Mutex(false)
if arguments.first == "serve" {
    guard let path = arguments.dropFirst().first else { answer(.init(status: 2, json: ["error": "serve <the container server's folder>"])) }
    let host: ServerHost
    do {
        host = try ContainerHostCommand.host(URL(fileURLWithPath: path, isDirectory: true), container: container, secrets: hostSecrets)
    } catch {
        answer(.init(status: 1, json: ["error": "No container server in \(path): \(error)", "code": "notFound"]))
    }
    let sources = [SIGTERM, SIGINT, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { stopped.withLock { $0 = true } }
        source.resume()
        return source
    }
    withExtendedLifetime(sources) { host.serve { stopped.withLock { $0 } } }
    exit(0)
}

// Only these are given anything on standard input.
let input = ["create", "put", "credentials"].contains(arguments.first ?? "") ? FileHandle.standardInput.readDataToEndOfFile() : Data()
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
answer(ContainerHostCommand.answer(arguments, input: input, container: container, version: version, secrets: hostSecrets))
