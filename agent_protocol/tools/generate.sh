#!/bin/bash
# The protos' Swift, made again: messages (protoc-gen-swift) and gRPC
# clients and servers (protoc-gen-grpc-swift-2), into Sources/AgentProtocol.
# The plugins are built from tools/plugins, at the package's own versions.
# protoc is $PROTOC, else on PATH.
# CI runs it and fails when what's kept differs (--check).
#
#   tools/generate.sh [--check]
set -euo pipefail
cd "$(dirname "$0")/.."
protoc="${PROTOC:-$(command -v protoc || true)}"
[ -x "$protoc" ] || { echo "generate.sh: no protoc (set PROTOC)" >&2; exit 1; }
include="$(dirname "$(dirname "$protoc")")/include"
scratch="${GENERATE_SCRATCH:-$(mktemp -d)}"
for product in protoc-gen-swift protoc-gen-grpc-swift-2; do
    swift build --package-path tools/plugins -c release --product "$product" --scratch-path "$scratch" > /dev/null
done
bin="$(swift build --package-path tools/plugins -c release --show-bin-path --scratch-path "$scratch")"
out="Sources/AgentProtocol"
if [ "${1:-}" = "--check" ]; then
    out="$(mktemp -d)"
fi
mkdir -p "$out"
"$protoc" -I protos ${include:+-I "$include"} \
    --plugin=protoc-gen-swift="$bin/protoc-gen-swift" --swift_opt=Visibility=Public --swift_out="$out" \
    --plugin=protoc-gen-grpc-swift-2="$bin/protoc-gen-grpc-swift-2" --grpc-swift-2_opt=Visibility=Public --grpc-swift-2_out="$out" \
    protos/agent_protocol/v1/*.proto
if [ "${1:-}" = "--check" ]; then
    diff -r "$out/agent_protocol" Sources/AgentProtocol/agent_protocol \
        || { echo "::error::Sources/AgentProtocol differs from the protos: run tools/generate.sh"; exit 1; }
    echo "The generated Swift matches the protos."
fi
