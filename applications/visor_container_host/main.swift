import Foundation
import VisorContainerHost

// visor-container-host <operation> [arguments] (docs/container-host.md).
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

// Only these are given anything on standard input.
let input = ["create", "put"].contains(arguments.first ?? "") ? FileHandle.standardInput.readDataToEndOfFile() : Data()
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
answer(ContainerHostCommand.answer(arguments, input: input, container: container, version: version))
