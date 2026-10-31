import Foundation
import VisorRunner

/// Apple's `container` for container servers: `run` (its arguments kept),
/// `inspect` (its state, labels and address, 127.0.0.1), `start`, `stop`,
/// `delete`, volumes, `system status`, and `exec`: a file written lands in
/// `fs/`, the network probe and the gateway are answered, and anything else
/// runs here with `visor-server` a fake on the PATH.
struct FakeContainer {
    let folder: URL

    var cli: ContainerCLI { ContainerCLI(tool: folder.appendingPathComponent("container").path) }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)", isDirectory: true)
        for sub in ["", "fs", "bin"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let container = #"""
            #!/bin/bash
            dir="$(dirname "$0")"
            echo "$*" >> "$dir/calls"
            case "$1" in
              system) exit 0 ;;
              volume)
                case "$2" in
                  inspect) [ -f "$dir/volume-$3" ] || exit 1; echo "[{}]" ;;
                  create) echo "$4" > "$dir/volume-$5" ;;
                  delete) rm -f "$dir/volume-$3" ;;
                esac ;;
              run) name=""; prev=""; for a in "$@"; do [ "$prev" = "--name" ] && name="$a"; prev="$a"; done
                touch "$dir/running-$name"; echo "$name" ;;
              inspect) status=""; [ -f "$dir/running-$2" ] && status=running; [ -f "$dir/stopped-$2" ] && status=stopped
                [ -n "$status" ] || exit 1
                echo "[{\"status\":\"$status\",\"networks\":[{\"address\":\"127.0.0.1/24\"}],\"configuration\":{\"id\":\"$2\",\"labels\":{}}}]" ;;
              start) [ -f "$dir/stopped-$2" ] || exit 1; mv "$dir/stopped-$2" "$dir/running-$2" ;;
              stop) [ -f "$dir/running-$2" ] || exit 1; mv "$dir/running-$2" "$dir/stopped-$2" ;;
              delete) rm -f "$dir/running-$3" "$dir/stopped-$3" ;;
              exec)
                shift; [ "$1" = "--interactive" ] && shift; shift
                if [ "$1" = rm ]; then rm -f "$dir/fs/$(echo "$3" | tr '/' '_')"; exit 0; fi
                case "$3" in
                  *'cat > "$1"'*) cat > "$dir/fs/$(echo "$5" | tr '/' '_')"; exit 0 ;;
                  *'getent hosts'*) [ -f "$dir/nonetwork" ] || printf 'dns\nreach\n'; exit 0 ;;
                  *'/proc/net/route'*) echo 0140A8C0; exit 0 ;;
                  # Files the Runner wrote in the container, where it reads them.
                  */root/.visor-runner/*) script="${3//\/root\/.visor-runner\//$dir/fs/_root_.visor-runner_}"
                    set -- "$1" "$2" "$script" "${@:4}" ;;
                esac
                PATH="$dir/bin:$PATH" exec "$@" ;;
            esac
            """#
        let server = #"""
            #!/bin/bash
            dir="$(cd "$(dirname "$0")/.." && pwd)"
            echo "visor-server $*" >> "$dir/calls"
            case "$1" in
              password) echo "$2" > "$dir/password" ;;
              start) port=""; prev=""; for a in "$@"; do [ "$prev" = "--port" ] && port="$a"; prev="$a"; done
                # The test's own server (FakeVisorServer) takes it from here.
                echo "$port" > "$dir/started" ;;
            esac
            """#
        try container.write(to: folder.appendingPathComponent("container"), atomically: true, encoding: .utf8)
        try server.write(to: folder.appendingPathComponent("bin/visor-server"), atomically: true, encoding: .utf8)
        for file in ["container", "bin/visor-server"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent(file).path)
        }
    }

    var calls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A file the Runner wrote in the container, by its path there.
    func written(_ path: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent("fs").appendingPathComponent(path.replacingOccurrences(of: "/", with: "_")),
                    encoding: .utf8)
    }

    func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }

    func touch(_ name: String) { _ = FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil) }

    func remove(_ name: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
}
