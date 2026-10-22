# Building on Linux

Builds the iOS app on Linux with
[rules_applecross](https://github.com/apple-cross-toolchain/rules_applecross)
and its clean-room Apple tools. Linux VMs could then run agents and CI for
this repository. For now it covers the simulator build of `visor_ios`: device
builds need the team's provisioning profiles.

```sh
RULES_APPLECROSS=~/Developer/rules_applecross tools/linux/build.sh [--local] [REF]
```

The script clones this repository at `REF` (default `main`) into a podman
volume. It builds there in rules_applecross's container (`tools/linux_vm`),
which reads the Mac's Xcode through a read-only mount, and writes
`.linux/visor_ios.ipa`. It needs the ported tools archive, built once with
rules_applecross's `tools/linux_vm/build-ported-tools.sh`. rules_applecross
comes from GitHub at the checkout's commit, or, with `--local`, from the
checkout itself.

`integrate.sh` makes the build's changes, which stay out of `main` until
rules_applecross releases them:

- rules_apple 5.3.1 and apple_support 2.10.1 with rules_applecross's patches,
  which only the root module can apply.
- A version-only override keeping rules_swift at 4.1.0.isomer.2
  (rules_applecross asks for 4.2.2).
- rules_applecross's toolchains, and its Linux settings in `.bazelrc.user`.
- swift-nio's and swift-crypto's manifests patched to take their
  `canImport(Darwin)` branch, since manifests are evaluated on the host. On
  Linux the apps would otherwise lose those packages' privacy manifests.

## Compared with the Xcode build

The simulator app has the same files as Xcode's build. Apple's `codesign
--verify --deep --strict` accepts it, and it runs in the iOS 18.4 and 27
simulators. Byte-identical with Xcode's:
`libswiftCompatibilitySpan.dylib` and the privacy manifests. Different: the
executables (swift.org's Swift compiler rather than Xcode's) and the icon
files (the `.icon` document is rendered flat).
