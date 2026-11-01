# Visor's machine layers for oss

oss (OS Server, [AttilaTheFun/oss](https://github.com/AttilaTheFun/oss))
makes vanilla machines; what Visor's sessions need on top of them, when
they lease them (through an OS Server's MCP tools their Visor server passes
on, or `oss machine lease …`), is here, built on the oss server's Mac with
oss's own commands. (The image Visor's sessions' containers are made from
is tools/containers: the container host makes each one.)

- `layers/`: the layers of the machines a session leases, each built on
  oss's vanilla base. On macOS, vanilla and one `xcode_<version>` per Xcode
  in use (at most the current one and the next): that Xcode, its iOS
  simulator, Homebrew, Git and Bazelisk, with no dev layer between
  (`oss_lease` with `config: xcode_27_2`). On Linux and Windows, a dev
  layer:

      oss image build macos xcode_27_2 --from=vanilla \
        --copy=/Applications/Xcode.app:/Applications/Xcode.app --script=tools/oss/layers/macos-xcode.sh
      oss image build linux dev --from=vanilla --script=tools/oss/layers/linux-dev.sh
      oss image build windows dev --from=vanilla --script=tools/oss/layers/windows-dev.ps1

  The Xcode build's last lines say what it has (`xcode:`, `ios:`, `git:`,
  `bazelisk:`): the Xcode and iOS versions must be the config's. (With
  `OSS_XCODE_VERSION` in its environment, the script checks both itself.)
  The older `dev` and `xcode-27.0` macOS images stay until CI's Mac jobs
  (tools/ci/mac_vm.sh) lease `xcode_27_2`.

