#!/bin/bash
# In the test VM, as `runner` (agent_protocol_e2e.sh runs it over ssh):
# Visor.app installed and started with agent_protocol's driver and
# dispatcher, MultiPass built from source and serving the relay with
# Visor's dial-in, and, for the Claude harness, Claude Code installed.
#
#   vm_setup.sh <claude|echo>     (in /tmp/e2e: visor_mac.zip, multipass.tar.gz)
#
# Standard input: the Claude token, then Visor's throwaway password, a line
# each. Both go to the desktop session's environment with launchctl setenv
# (the agents and Visor.app inherit it from there), so neither is ever
# written to a file or a log. (launchctl takes the value as its argument,
# so it is briefly on that command line, inside this throwaway VM.)
set -euo pipefail
harness="${1:?claude or echo}"
cd /tmp/e2e
IFS= read -r token
IFS= read -r password
user_id="$(id -u)"
desktop() { sudo launchctl asuser "$user_id" sudo -u "$(id -un)" "$@"; }
say() { echo "vm_setup: $*"; }

say "Visor.app"
rm -rf app && mkdir app && ditto -x -k visor_mac.zip app
sudo rm -rf /Applications/Visor.app
sudo ditto app/Visor.app /Applications/Visor.app
sudo chown -R "$(id -un):staff" /Applications/Visor.app
xattr -cr /Applications/Visor.app
rm -rf app

claude="$HOME/.local/bin/claude"
if [ "$harness" = claude ]; then
    say "Claude Code"
    curl -fsSL https://claude.ai/install.sh | bash > /tmp/e2e/claude-install.log 2>&1 \
        || { tail -5 /tmp/e2e/claude-install.log; exit 1; }
    [ -x "$claude" ] || { echo "vm_setup: Claude Code isn't at $claude" >&2; exit 1; }
fi

say "MultiPass (built here: its repository is private, so it came as source)"
rm -rf "$HOME/multipass" && mkdir "$HOME/multipass"
tar -xzf multipass.tar.gz -C "$HOME/multipass" --strip-components 1
(cd "$HOME/multipass" && xcrun swift build -c release --product multipass-agent > /tmp/e2e/multipass-build.log 2>&1) \
    || { tail -20 /tmp/e2e/multipass-build.log; exit 1; }
mkdir -p "$HOME/bin" "$HOME/mp"
cp "$HOME/multipass/.build/release/multipass-agent" "$HOME/bin/"
multipass() { "$HOME/bin/multipass-agent" --data "$HOME/mp" "$@"; }
multipass github-proxy port 7471 > /dev/null
multipass relay port 7470 > /dev/null
multipass dial-in add visor 7434 > /dev/null
nohup "$HOME/bin/multipass-agent" --data "$HOME/mp" serve > "$HOME/mp/agent.log" 2>&1 < /dev/null &
disown

say "the agents' environment, in the desktop session's launchd only"
desktop launchctl setenv CLAUDE_CODE_OAUTH_TOKEN "$token"
desktop launchctl setenv VISOR_SETUP_PASSWORD "$password"
desktop launchctl setenv AGENT_WRAPPER_CLAUDE "$claude"
unset token password
defaults write com.LoganShire.Visor AgentJobHarness "$harness"
defaults write com.LoganShire.Visor AgentProtocolContainerURL http://visor.multipass.internal:7434
mkdir -p "$HOME/e2e-native"

say "Visor.app started"
desktop open -a /Applications/Visor.app
for _ in $(seq 1 60); do
    if [ -S "$HOME/.visor/server.sock" ] && lsof -nP -iTCP:7434 -sTCP:LISTEN > /dev/null 2>&1 \
        && lsof -nP -iTCP:7470 -sTCP:LISTEN > /dev/null 2>&1; then
        say "ready: Visor's socket, its driver and dispatcher on 7434, MultiPass's relay on 7470"
        exit 0
    fi
    sleep 2
done
echo "vm_setup: Visor or MultiPass didn't come up within two minutes" >&2
exit 1
