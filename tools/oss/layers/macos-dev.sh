#!/bin/bash
# The dev layer on macOS: Homebrew (which brings Apple's Command Line Tools,
# its own requirement), and through it Bazelisk, Git and Chrome.
set -euo pipefail
if [ ! -x /opt/homebrew/bin/brew ]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install bazelisk git
brew install --cask google-chrome
echo "dev: $(git --version); bazelisk $(bazelisk version 2>/dev/null | head -1)"
