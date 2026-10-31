#!/bin/bash
# The command-line server on Windows, in a Windows VM leased from OS Server
# (swift-6.3.2: Swift and MSVC's build tools): built with SwiftPM in MSVC's
# environment, then tried — run, a throwaway session over its WebSocket,
# stopped through its REST side (tools/probes/server.mjs, with node brought
# in, checked by its SHA-256 and kept on the runner between runs).
#
#   tools/ci/windows_vm_tests.sh
#
# The VM is the script's alone: leased for an hour, renewed while it runs,
# released however it ends (a kill nothing can trap leaves it an hour at
# most). The committed tree goes in (git archive).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
CONFIG="swift-6.3.2"
NODE_VERSION="v22.23.4"
NODE_SHA256="a8b8cd79cbbb3062435f449591d98dd63730bbbf30ce2d7cc3a6376c236cb111"

work="$(mktemp -d)"
chmod 700 "$work"
lease=""
renewer=""
child=""
finished=""

release() {
    if [ -n "$renewer" ]; then
        kill "$renewer" 2> /dev/null || true
        wait "$renewer" 2> /dev/null || true
        renewer=""
    fi
    # A lease asked for as the script was stopped: its id, if it came.
    [ -n "$lease" ] || lease="$(. "$work/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$lease" ]; then
        "$OSS" machine release "$lease" || echo "windows_vm_tests.sh: lease $lease was not released: oss machine release $lease" >&2
        lease=""
        rm -f "$work/lease"
    fi
}
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    release
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Long commands run in the background and are waited for, so a signal (the
# runner cancelling the job) reaches the trap at once, not when they end.
run() {
    "$@" &
    child=$!
    local status=0
    wait "$child" || status=$?
    child=""
    return "$status"
}
# A PowerShell command in the VM, over SSH.
ps() { "$OSS" machine ssh "$lease" --identity="$work/key" -- "$1"; }

# node for the VM, from nodejs.org, checked, kept on the runner between runs.
cache="${RUNNER_TOOL_CACHE:-$HOME/Library/Caches}/visor-ci"
node="$cache/node-$NODE_VERSION-win-arm64.zip"
mkdir -p "$cache" "$work/vm"
if ! echo "$NODE_SHA256  $node" | shasum -a 256 -c - > /dev/null 2>&1; then
    curl -fsSL -o "$node.part" "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-win-arm64.zip"
    echo "$NODE_SHA256  $node.part" | shasum -a 256 -c - > /dev/null
    mv "$node.part" "$node"
fi
cp "$node" "$work/vm/node.zip"
git -C "$ROOT" archive --format=tar -o "$work/vm/tree.tar" HEAD
# What the VM runs, as files (a command over SSH is one line): the tree and
# node unpacked into C:\ci, SwiftPM in MSVC's environment (it finds link.exe
# there), and the server tried.
printf '%s\r\n' \
    'New-Item -ItemType Directory -Force C:\ci\visor, C:\ci\node | Out-Null' \
    'tar -xf C:\Users\runner\ci\tree.tar -C C:\ci\visor; if ($LASTEXITCODE) { exit 1 }' \
    'tar -xf C:\Users\runner\ci\node.zip -C C:\ci\node --strip-components 1; if ($LASTEXITCODE) { exit 1 }' \
    'swift --version' > "$work/vm/unpack.ps1"
printf '%s\r\n' \
    '$env:PATH = "C:\ci\node;" + $env:PATH' \
    'cd C:\ci\visor' \
    '$server = ".build\debug\visor-server.exe"' \
    '$password = & $server password' \
    'Start-Process -FilePath $server -ArgumentList "run","--port","7633" -NoNewWindow -RedirectStandardOutput server.log -RedirectStandardError server-errors.log' \
    'Start-Sleep 3' \
    '$env:VISOR_PORT = "7633"; $env:VISOR_TOKEN = $password; $env:QUIT = "1"' \
    'node tools/probes/server.mjs' \
    '$probe = $LASTEXITCODE' \
    'Get-Content server.log, server-errors.log' \
    'exit $probe' > "$work/vm/probe.ps1"
printf '%s\r\n' '@echo off' \
    'call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" arm64 >nul' \
    'cd /d C:\ci\visor' \
    'swift build --product visor-server' > "$work/vm/build.cmd"

echo "::group::A Windows VM ($CONFIG)"
ssh-keygen -q -t ed25519 -N '' -C visor-ci -f "$work/key"
run "$OSS" machine lease windows --config="$CONFIG" --minutes=60 --wait --key="$work/key.pub" --exports > "$work/lease"
lease="$(. "$work/lease"; printf '%s' "$OSS_ID")"
echo "Leased $lease"
(
    trap 'kill $! 2> /dev/null; exit 0' TERM
    while :; do
        sleep 600 &
        wait $!
        "$OSS" machine renew "$lease" --minutes=60 > /dev/null || true
    done
) &
renewer=$!
for _ in $(seq 1 30); do ps 'exit 0' 2> /dev/null && break; sleep 5; done
run "$OSS" machine upload "$lease" --identity="$work/key" "$work/vm" ci
run ps 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\runner\ci\unpack.ps1; exit $LASTEXITCODE'
echo "::endgroup::"

status=0
echo "::group::Build"
run ps 'cmd /c C:\Users\runner\ci\build.cmd; exit $LASTEXITCODE' || status=$?
echo "::endgroup::"
if [ "$status" -eq 0 ]; then
    echo "::group::Try the server"
    run ps 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\runner\ci\probe.ps1; exit $LASTEXITCODE' || status=$?
    echo "::endgroup::"
fi
[ "$status" -eq 0 ] || echo "::error::the Windows server failed ($status)"
release
finished=1
exit "$status"
