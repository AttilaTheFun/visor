# Visor's machine layers for oss

oss (OS Server, [AttilaTheFun/oss](https://github.com/AttilaTheFun/oss))
makes vanilla machines; what Visor's sessions need on top of them, when
they lease them through their Visor server (`visor machine lease …`), is
here, built on the oss server's Mac with oss's own commands. (The image
Visor's sessions' containers are made from is tools/containers: the Visor
server leases each one from the OS Server on its own Mac.)

- `layers/`: the dev and Xcode layers of the machines a session leases
  (`visor machine lease macos --config=xcode-27.0`), each built on oss's
  vanilla base:

      oss image build macos dev --from=vanilla --script=tools/oss/layers/macos-dev.sh
      oss image build macos xcode-27.0 --from=dev --copy=/Applications/Xcode.app:/Applications/Xcode.app \
        --script=tools/oss/layers/macos-xcode.sh
      oss image build linux dev --from=vanilla --script=tools/oss/layers/linux-dev.sh
      oss image build windows dev --from=vanilla --script=tools/oss/layers/windows-dev.ps1

