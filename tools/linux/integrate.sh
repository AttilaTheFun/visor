#!/bin/bash
# Adds rules_applecross to this checkout (run from its root, in the build
# container); see README.md. RULES_APPLECROSS is a rules_applecross checkout
# with the ported tools archive built.
#
#   integrate.sh --commit SHA | --local
set -euo pipefail
SRC="${RULES_APPLECROSS:?set RULES_APPLECROSS to a rules_applecross checkout}"
case "${1:-}" in
  --commit) AC=""; COMMIT="$2" ;;
  --local) AC="$SRC"; COMMIT="" ;;
  *) echo "usage: integrate.sh --commit SHA | --local" >&2; exit 2 ;;
esac

mkdir -p third_party/patches/applecross
cp "$SRC"/patches/*.patch third_party/patches/applecross/
cp "$SRC/ported-tools-linux-$(uname -m).tar.xz" .

python3 - "$AC" "$COMMIT" <<'PY'
import sys
path, commit = sys.argv[1], sys.argv[2]
p = "MODULE.bazel"
s = open(p).read()
assert '''bazel_dep(name = "rules_swift", version = "4.1.0.isomer.2")''' in s
old_apple = '''bazel_dep(name = "rules_apple", version = "5.1.0")'''
assert old_apple in s
s = s.replace(old_apple, '''bazel_dep(name = "rules_apple", version = "5.3.1")''')
old = '''    patches = ["//third_party/patches:rules_apple_device_xctrunner.patch"],
)'''
assert old in s
s = s.replace(old, '''    patches = [
        "//third_party/patches:rules_apple_device_xctrunner.patch",
        "//third_party/patches/applecross:rules_apple_execution_platform.patch",
        "//third_party/patches/applecross:rules_apple_bundletool_path.patch",
        "//third_party/patches/applecross:rules_apple_no_absolute_tool_paths.patch",
        "//third_party/patches/applecross:rules_apple_codesign_inputs_sdk_tools.patch",
        "//third_party/patches/applecross:rules_apple_python_stub_interpreter.patch",
        "//third_party/patches/applecross:rules_apple_alticonstool_missing_icons.patch",
        "//third_party/patches/applecross:rules_apple_dossier_zipfile.patch",
    ],
    version = "5.3.1",
)''')
if path:
    override = 'local_path_override(\n    module_name = "rules_applecross",\n    path = "%s",\n)' % path
else:
    override = 'git_override(\n    module_name = "rules_applecross",\n    commit = "%s",\n    remote = "https://github.com/apple-cross-toolchain/rules_applecross.git",\n)' % commit
s += '''
# rules_applecross: Apple builds on Linux.
bazel_dep(name = "rules_applecross", version = "0.0.3")
%s

single_version_override(
    module_name = "apple_support",
    patch_strip = 1,
    patches = ["//third_party/patches/applecross:apple_support_bazel8_xcode_properties.patch"],
    version = "2.10.1",
)

# Keep isomer's rules_swift over rules_applecross's 4.2.2.
single_version_override(
    module_name = "rules_swift",
    version = "4.1.0.isomer.2",
)

apple_cross_toolchain = use_extension("@rules_applecross//toolchain:extensions.bzl", "apple_cross_toolchain")
use_repo(apple_cross_toolchain, "apple_cross_toolchain")

register_toolchains(
    "@rules_applecross//toolchain:apple_bundling_on_linux",
    "@apple_cross_toolchain//:all",
)
''' % override
# Manifests are evaluated on the host; keep their Darwin-only privacy manifests.
configure = "".join('''swift_deps.configure_package(
    name = "%s",
    patch_cmds = ["sed -i.orig 's/^#if canImport(Darwin)$/#if true/' Package.swift"],
)

''' % name for name in ["swift-crypto", "swift-nio"])
anchor = "use_repo(\n    swift_deps,"
assert anchor in s
s = s.replace(anchor, configure + anchor, 1)
open(p, "w").write(s)
PY

echo "exports_files(glob([\"*.patch\"]))" > third_party/patches/applecross/BUILD.bazel

TC=external/rules_applecross++apple_cross_toolchain+apple_cross_toolchain/Xcode.app/Contents/Developer
cat > .bazelrc.user <<RC
# rules_applecross on Linux.
startup --host_jvm_args=-DBAZEL_TRACK_SOURCE_DIRECTORIES=1
common --enable_platform_specific_config
common:linux --repo_env=BAZEL_NO_APPLE_CPP_TOOLCHAIN=1
common:linux --incompatible_repo_env_ignores_action_env
build:linux --xcode_version_config=@apple_cross_toolchain//:host_xcodes
build:linux --@rules_apple//apple:sdk_tool_files=@apple_cross_toolchain//:sdk_tool_files
build:linux --action_env=DEVELOPER_DIR=$TC
build:linux --action_env=PATH=$TC/Toolchains/XcodeDefault.xctoolchain/usr/bin:/bin:/usr/bin:/usr/local/bin
RC
