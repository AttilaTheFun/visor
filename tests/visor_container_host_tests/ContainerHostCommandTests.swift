// visor-container-host's operations (docs/container-host.md) over a script
// that plays Apple's `container`: what each asks of the tool, and what it
// answers Visor.

import Foundation
@testable import VisorContainerHost
import XCTest

/// Apple's `container` played by a script: each call written down, its
/// containers and volumes files beside it (`running-<id>`, `stopped-<id>`,
/// `volume-<name>` holding its size, `spec-<id>` the request's digest it
/// was labelled with), and answers as the test sets them
/// (`stopped`, `noimage`, `nodns`, `noreach`, `list.json`).
private struct FakeTool {
    let folder: URL

    var path: String { folder.appendingPathComponent("container").path }
    var tool: AppleContainer { AppleContainer(tool: path) }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("container-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = #"""
            #!/bin/bash
            dir="$(dirname "$0")"
            echo "$*" >> "$dir/calls"
            case "$1 $2" in
              "system status") [ -f "$dir/stopped" ] && exit 1; echo running ;;
              "volume inspect") [ -f "$dir/volume-$3" ] || exit 1
                echo "[{\"configuration\":{\"name\":\"$3\",\"sizeInBytes\":$(cat "$dir/volume-$3")}}]" ;;
              "volume create") echo $(( ${4%M} * 1048576 )) > "$dir/volume-$5" ;;
              "volume delete") rm -f "$dir/volume-$3" ;;
              "volume list") printf '['; sep=""
                for f in "$dir"/volume-*; do [ -f "$f" ] || continue; printf '%s{"configuration":{"name":"%s"}}' "$sep" "${f##*/volume-}"; sep=","; done
                echo ']' ;;
              *)
                case "$1" in
                  run) [ -f "$dir/noimage" ] && { echo "Error: image not found" >&2; exit 1; }
                    name=""; spec=""; prev=""
                    for a in "$@"; do
                      [ "$prev" = "--name" ] && name="$a"
                      [ "$prev" = "--label" ] && case "$a" in visor.host.spec=*) spec="${a#visor.host.spec=}" ;; esac
                      prev="$a"
                    done
                    echo "$spec" > "$dir/spec-$name"; touch "$dir/running-$name"; echo "$name" ;;
                  exec)
                    if [ "$2" = "--interactive" ]; then path="${@: -2:1}"; cat > "$dir/put-$(echo "$path" | tr '/' '_')"; exit 0; fi
                    case "$*" in
                      *curl*) [ -f "$dir/nodns" ] || echo dns; [ -f "$dir/nodns" ] || [ -f "$dir/noreach" ] || echo reach ;;
                      *getent*) [ -f "$dir/nodns" ] && exit 1; exit 0 ;;
                    esac ;;
                  delete) rm -f "$dir/running-$3" "$dir/stopped-$3" ;;
                  list) if [ -f "$dir/list.json" ]; then cat "$dir/list.json"; else echo '[]'; fi ;;
                  inspect) status=""; [ -f "$dir/running-$2" ] && status=running; [ -f "$dir/stopped-$2" ] && status=stopped
                    [ -n "$status" ] || exit 1
                    echo "[{\"status\":\"$status\",\"configuration\":{\"labels\":{\"visor.host.spec\":\"$(cat "$dir/spec-$2" 2>/dev/null)\"}}}]" ;;
                  start) [ -f "$dir/stopped-$2" ] || exit 1; mv "$dir/stopped-$2" "$dir/running-$2" ;;
                esac ;;
            esac
            """#
        try script.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// The calls made, one a line: the tool's arguments.
    var calls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func set(_ name: String, _ contents: String = "") throws {
        try contents.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }

    func read(_ name: String) -> String? { try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

final class ContainerHostCommandTests: XCTestCase {
    private var fake: FakeTool!

    override func setUp() async throws { fake = try FakeTool() }

    override func tearDown() async throws { fake.remove() }

    private let request = Data(#"""
        {"api": 1, "name": "visor-s1", "image": "ghcr.io/example/agent:1", "cpus": 6, "memoryBytes": 17179869184,
         "mounts": [{"source": "/Users/me/project", "destination": "/Users/me/project", "readOnly": false},
                    {"source": "/Users/me/.tools", "destination": "/opt/tools", "readOnly": true}],
         "volumes": [{"name": "visor-s1-build", "destination": "/var/cache/bazel", "sizeBytes": 137438953472}],
         "environment": {"VISOR_URL": "ws://host:7633"}, "rosetta": true,
         "labels": {"visor.session": "s1", "visor.server": "server"}}
        """#.utf8)

    func testHealthSaysWhetherTheToolIsThereAndStarted() throws {
        let healthy = ContainerHostCommand.answer(["health"], input: Data(), container: fake.tool, version: "0.44.0")
        XCTAssertEqual(healthy.status, 0)
        XCTAssertEqual(healthy.json["ok"] as? Bool, true)
        XCTAssertEqual(healthy.json["api"] as? Int, 1)
        XCTAssertEqual(healthy.json["name"] as? String, "visor-container-host")
        XCTAssertEqual(healthy.json["version"] as? String, "0.44.0")
        let limits = try XCTUnwrap(healthy.json["limits"] as? [String: Any])
        XCTAssertEqual(limits["cpus"] as? Int, ProcessInfo.processInfo.activeProcessorCount)

        try fake.set("stopped")
        let stopped = ContainerHostCommand.answer(["health"], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(stopped.json["ok"] as? Bool, false)
        XCTAssertTrue((stopped.json["error"] as? String ?? "").contains("container system start"))

        let missing = ContainerHostCommand.answer(["health"], input: Data(), container: AppleContainer(tool: "/nonexistent/container"), version: "")
        XCTAssertEqual(missing.json["ok"] as? Bool, false)
        XCTAssertTrue((missing.json["error"] as? String ?? "").contains("not installed"))
    }

    func testCreateMakesItsVolumeAndRunsTheContainer() throws {
        let made = ContainerHostCommand.create(request, container: fake.tool, rosetta: true, tries: 1, pause: 0)
        XCTAssertEqual(made.status, 0, made.text)
        XCTAssertEqual(made.json["id"] as? String, "visor-s1")
        XCTAssertEqual(made.json["cpus"] as? Int, 6)
        XCTAssertEqual(fake.read("volume-visor-s1-build")?.trimmingCharacters(in: .whitespacesAndNewlines), "137438953472")
        let run = try XCTUnwrap(fake.calls.first { $0.hasPrefix("run ") })
        let spec = ContainerHostCommand.spec(of: try JSONDecoder().decode(HostRequest.self, from: request))
        XCTAssertEqual(run, "run --detach --name visor-s1 --volume visor-s1-build:/var/cache/bazel"
            + " --mount type=bind,source=/Users/me/project,target=/Users/me/project"
            + " --mount type=bind,source=/Users/me/.tools,target=/opt/tools,readonly"
            + " --label visor.host=visor-container-host --label visor.host.spec=\(spec) --label visor.server=server --label visor.session=s1"
            + " --cpus 6 --memory 16384M --env VISOR_URL=ws://host:7633 --rosetta ghcr.io/example/agent:1 sleep infinity")
        // Handed over once it resolves names.
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("exec visor-s1 sh -c getent hosts") })
    }

    func testRosettaOnlyWhereAskedAndHere() throws {
        _ = ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 1, pause: 0)
        XCTAssertFalse(try XCTUnwrap(fake.calls.first { $0.hasPrefix("run ") }).contains("--rosetta"))
        let plain = HostRequest(name: "n", image: "i")
        XCTAssertEqual(ContainerHostCommand.runArguments(plain, rosetta: true),
                       ["run", "--detach", "--name", "n", "--label", "visor.host=visor-container-host",
                        "--label", "visor.host.spec=" + ContainerHostCommand.spec(of: plain), "i", "sleep", "infinity"])
    }

    func testAVolumeAtItsSizeIsKeptAndOneAtAnotherMadeAgain() throws {
        try fake.set("volume-visor-s1-build", "137438953472")
        _ = ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 1, pause: 0)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("volume delete") || $0.hasPrefix("volume create") })

        // Made again (the container gone, its disk kept) with the disk at another size.
        _ = ContainerHostCommand.answer(["rm", "visor-s1"], input: Data(), container: fake.tool, version: "")
        try fake.set("volume-visor-s1-build", "68719476736")
        _ = ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 1, pause: 0)
        XCTAssertTrue(fake.calls.contains("volume delete visor-s1-build"))
        XCTAssertTrue(fake.calls.contains("volume create -s 131072M visor-s1-build"))
    }

    func testCreateAskedAgainAnswersTheOneItMade() throws {
        XCTAssertEqual(ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 1, pause: 0).status, 0)
        let again = ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 1, pause: 0)
        XCTAssertEqual(again.status, 0, again.text)
        XCTAssertEqual(again.json["id"] as? String, "visor-s1")
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("run ") }.count, 1)

        // Stopped meanwhile (the Mac restarted): started again.
        try FileManager.default.moveItem(at: fake.folder.appendingPathComponent("running-visor-s1"),
                                         to: fake.folder.appendingPathComponent("stopped-visor-s1"))
        XCTAssertEqual(ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 1, pause: 0).status, 0)
        XCTAssertTrue(fake.calls.contains("start visor-s1"))
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("run ") }.count, 1)
    }

    func testCreateRefusesANameMadeOtherwise() throws {
        XCTAssertEqual(ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 1, pause: 0).status, 0)
        let other = Data(String(decoding: request, as: UTF8.self).replacingOccurrences(of: "agent:1", with: "agent:2").utf8)
        let refused = ContainerHostCommand.create(other, container: fake.tool, rosetta: false, tries: 1, pause: 0)
        XCTAssertEqual(refused.status, 1)
        XCTAssertEqual(refused.json["code"] as? String, "exists")
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("run ") }.count, 1)
    }

    func testAMissingImageIsNoImage() throws {
        try fake.set("noimage")
        let made = ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 1, pause: 0)
        XCTAssertEqual(made.status, 1)
        XCTAssertEqual(made.json["code"] as? String, "noImage")
        XCTAssertTrue((made.json["error"] as? String ?? "").contains("image not found"))
    }

    func testOneThatResolvesNothingIsNotHandedOver() throws {
        try fake.set("nodns")
        let made = ContainerHostCommand.create(request, container: fake.tool, rosetta: false, tries: 2, pause: 0)
        XCTAssertEqual(made.status, 1)
        XCTAssertEqual(made.json["code"] as? String, "network")
        XCTAssertEqual(fake.calls.filter { $0.contains("getent") }.count, 2)
        XCTAssertTrue(fake.calls.contains("delete --force visor-s1"))
        XCTAssertFalse(fake.has("running-visor-s1"))
    }

    func testCreateRefusesWhatIsNotARequest() throws {
        XCTAssertEqual(ContainerHostCommand.create(Data("nope".utf8), container: fake.tool, rosetta: false).status, 1)
        let badName = Data(#"{"name": "a b; rm", "image": "i"}"#.utf8)
        XCTAssertEqual(ContainerHostCommand.create(badName, container: fake.tool, rosetta: false).status, 1)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testPutWritesItsInputAtThePath() throws {
        let put = ContainerHostCommand.answer(["put", "visor-s1", "/root/.claude.json", "--mode=644"], input: Data("{}".utf8),
                                              container: fake.tool, version: "")
        XCTAssertEqual(put.status, 0, put.text)
        XCTAssertEqual(put.json["path"] as? String, "/root/.claude.json")
        XCTAssertEqual(put.json["size"] as? Int, 2)
        XCTAssertEqual(fake.read("put-_root_.claude.json"), "{}")
        XCTAssertTrue(try XCTUnwrap(fake.calls.last).hasSuffix("sh /root/.claude.json 644"))
    }

    func testRemoveTakesItsOwnVolumesOnlyWhenAsked() throws {
        try fake.set("running-visor-s1")
        try fake.set("volume-visor-s1-build", "1")
        try fake.set("volume-visor-s10-build", "1")
        let kept = ContainerHostCommand.answer(["rm", "visor-s1"], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(kept.json["removed"] as? String, "visor-s1")
        XCTAssertFalse(fake.has("running-visor-s1"))
        XCTAssertTrue(fake.has("volume-visor-s1-build"))

        let removed = ContainerHostCommand.answer(["rm", "visor-s1", "--volumes"], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(removed.status, 0)
        XCTAssertFalse(fake.has("volume-visor-s1-build"))
        XCTAssertTrue(fake.has("volume-visor-s10-build"))
    }

    func testListIsVisorsContainersOnly() throws {
        try fake.set("list.json", #"""
            [{"status": "running", "configuration": {"id": "visor-s1", "image": {"reference": "ghcr.io/example/agent:1"},
              "labels": {"visor.session": "s1", "visor.server": "server"}}},
             {"status": "stopped", "configuration": {"id": "other", "image": {"reference": "alpine"}, "labels": {}}}]
            """#)
        let listed = ContainerHostCommand.answer(["ls"], input: Data(), container: fake.tool, version: "")
        let containers = try XCTUnwrap(listed.json["containers"] as? [[String: Any]])
        XCTAssertEqual(containers.count, 1)
        XCTAssertEqual(containers.first?["id"] as? String, "visor-s1")
        XCTAssertEqual(containers.first?["state"] as? String, "running")
        XCTAssertEqual(containers.first?["image"] as? String, "ghcr.io/example/agent:1")
        XCTAssertEqual((containers.first?["labels"] as? [String: String])?["visor.server"], "server")
    }

    func testNetworkSaysWhatWorks() throws {
        let fine = ContainerHostCommand.answer(["network", "visor-s1"], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(fine.json["ok"] as? Bool, true)
        try fake.set("noreach")
        let unreached = ContainerHostCommand.answer(["network", "visor-s1"], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(unreached.json["ok"] as? Bool, false)
        XCTAssertEqual(unreached.json["dns"] as? Bool, true)
        try fake.set("nodns")
        let unresolved = ContainerHostCommand.answer(["network", "visor-s1"], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(unresolved.json["dns"] as? Bool, false)
        XCTAssertTrue((unresolved.json["detail"] as? String ?? "").contains("resolves no names"))
    }

    func testExecIsContainerExec() throws {
        let run = try XCTUnwrap(ContainerHostCommand.execArguments(["visor-s1", "--interactive", "--workdir=/Users/me/project",
                                                                    "--env-file=/tmp/vars", "--", "claude", "-p", "--"]))
        XCTAssertEqual(run.id, "visor-s1")
        XCTAssertEqual(run.arguments, ["exec", "--interactive", "--workdir", "/Users/me/project", "--env-file", "/tmp/vars",
                                       "visor-s1", "claude", "-p", "--"])
        XCTAssertEqual(ContainerHostCommand.execArguments(["visor-s1", "--", "true"])?.arguments, ["exec", "--interactive", "visor-s1", "true"])
        XCTAssertEqual(ContainerHostCommand.execArguments(["visor-s1", "--tty", "--", "bash"])?.arguments,
                       ["exec", "--interactive", "--tty", "visor-s1", "bash"])
        XCTAssertNil(ContainerHostCommand.execArguments(["visor-s1", "true"]))
        XCTAssertNil(ContainerHostCommand.execArguments(["visor-s1", "--"]))
    }

    func testExecStartsAStoppedContainerFirst() throws {
        try fake.set("running-a")
        XCTAssertTrue(ContainerHostCommand.started("a", container: fake.tool))
        XCTAssertFalse(fake.calls.contains("start a"))
        try fake.set("stopped-b")
        XCTAssertTrue(ContainerHostCommand.started("b", container: fake.tool))
        XCTAssertTrue(fake.has("running-b"))
        XCTAssertFalse(ContainerHostCommand.started("c", container: fake.tool))
    }

    func testAnUnknownOperationIsUnsupported() {
        let answer = ContainerHostCommand.answer(["snapshot"], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(answer.status, 1)
        XCTAssertEqual(answer.json["code"] as? String, "unsupported")
    }
}
