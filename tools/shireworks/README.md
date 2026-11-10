# Visor's machine layers for Shireworks

Shireworks ([AttilaTheFun/shireworks](https://github.com/AttilaTheFun/shireworks))
makes vanilla machines; what Visor's sessions need on top of them, when
they lease them (through the Shireworks MCP tools their Visor server passes
on, or tools/ci/shireworks.sh), is here, built on the Shireworks server's
Mac with Shireworks' own image builds. (The image Visor's sessions'
containers are made from is tools/containers: the container host makes
each one.)

- `layers/`: the layers of the machines a session leases, each built on
  Shireworks' vanilla base. On macOS, vanilla and one `xcode_<version>` per
  Xcode in use (at most the current one and the next): that Xcode, its iOS
  simulator, Homebrew, Git and Bazelisk, with no dev layer between (a lease
  with `config: xcode_27_2`). On Linux and Windows, a dev layer. Built on
  the server's Mac with Shireworks' image build command, as its README
  names it (Your own layers):

      <image build> macos xcode_27_2 --from=vanilla \
        --copy=/Applications/Xcode.app:/Applications/Xcode.app --script=tools/shireworks/layers/macos-xcode.sh
      <image build> linux dev --from=vanilla --script=tools/shireworks/layers/linux-dev.sh
      <image build> windows dev --from=vanilla --script=tools/shireworks/layers/windows-dev.ps1

  The Xcode build's last lines say what it has (`xcode:`, `ios:`, `git:`,
  `bazelisk:`): the Xcode and iOS versions must be the config's. (With
  `VISOR_XCODE_VERSION` in its environment, the script checks both itself.)
  `xcode_27_2` is the Xcode config CI's Mac jobs lease (tools/ci/mac_vm.sh);
  the older `xcode-27.0` image is gone.
