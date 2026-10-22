# Visor's images for oss

oss (OS Server, [AttilaTheFun/oss](https://github.com/AttilaTheFun/oss))
makes vanilla machines and plain containers; what Visor's agents need on
top of them is here, built on the oss server's Mac with oss's own
commands.

- `visor-agent/Dockerfile`: the image the Visor server makes its sessions'
  containers from (`visor-server oss image`, visor-agent by default):
  Claude Code, Codex, Node (which runs Visor's MCP script), git, ssh,
  tmux, Python, bazelisk, and oss's CLI (`oss mcp`, with which an agent
  leases machines on its container's own token). Its sign-ins are the oss
  server's, per image (`~/.config/oss/images/visor-agent.env` and
  `.home/`), never in the image.

      oss image build container visor-agent --dockerfile=tools/oss/visor-agent/Dockerfile

- `layers/`: the dev and Xcode layers of the machines an agent leases
  (`oss machine lease macos --config=xcode-27.0`), each built on oss's
  vanilla base:

      oss image build macos dev --from=vanilla --script=tools/oss/layers/macos-dev.sh
      oss image build macos xcode-27.0 --from=dev --copy=/Applications/Xcode.app:/Applications/Xcode.app \
        --script=tools/oss/layers/macos-xcode.sh
      oss image build linux dev --from=vanilla --script=tools/oss/layers/linux-dev.sh
      oss image build windows dev --from=vanilla --script=tools/oss/layers/windows-dev.ps1

The agents in the image are the newest when it is built: build it again
to take newer ones.
