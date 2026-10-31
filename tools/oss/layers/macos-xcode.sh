#!/bin/bash
# The xcode_<version> layer on macOS, built from oss's vanilla base: that
# Xcode and its iOS simulator, with Homebrew (which brings Apple's Command
# Line Tools, its own requirement) and through it Git and Bazelisk. Its
# build copies the oss server Mac's Xcode (its version must match) to
# /Applications first (tools/oss/README.md). No Chrome: blue's web checks
# run in a Linux container (tools/ci/container_blue_web.sh).
#
# What a command says is taken whole before its first line is: a reader
# that stops early (head) ends the writer with SIGPIPE, which pipefail
# takes for the script's failure.
set -euo pipefail
first() { printf '%s\n' "${1%%$'\n'*}"; }

test -d /Applications/Xcode.app || { echo "no /Applications/Xcode.app (the build copies it in)" >&2; exit 1; }
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
about="$(xcodebuild -version)"
version="$(first "$about")"
if [ -n "${OSS_XCODE_VERSION:-}" ] && [[ "$version" != "Xcode ${OSS_XCODE_VERSION}"* ]]; then
  echo "this is $version, not Xcode $OSS_XCODE_VERSION" >&2; exit 1
fi

if [ ! -x /opt/homebrew/bin/brew ]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install bazelisk git

# The iOS simulator runtime, from Apple (no Apple Account needed).
xcodebuild -downloadPlatform iOS
runtimes="$(xcrun simctl list runtimes)"
ios="$(printf '%s\n' "$runtimes" | grep -i '^iOS ' || true)"
[ -n "$ios" ] || { echo "no iOS simulator runtime" >&2; exit 1; }
if [ -n "${OSS_XCODE_VERSION:-}" ] && ! printf '%s\n' "$ios" | grep -q "^iOS ${OSS_XCODE_VERSION}"; then
  echo "the iOS runtime is not ${OSS_XCODE_VERSION}: $ios" >&2; exit 1
fi

bazelisk="$(bazelisk version 2>/dev/null || true)"
echo "xcode: $version"
echo "ios: $(first "$ios")"
echo "git: $(git --version)"
echo "bazelisk: $(first "$bazelisk")"
