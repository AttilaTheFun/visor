#!/bin/bash
# A publishing job's builds signed and saved as a release's assets, on
# GitHub's own Linux runner, with nothing of Shireworks' (Logan, 15 Nov
# 2026: a public repository signs in its own job, its keys in its GitHub
# secrets): each package signed in the job itself by the signers copied
# byte for byte from AttilaTheFun/shireworks (tools/ci/android_sign.sh,
# tools/ci/apple_sign.sh with apple_profiles.py beside it), its keys from
# the job's GitHub environment (`release`: main and v* tags), then its
# builds.json line written from the signed package (tools/ci/release_assets.sh's
# release_asset_file), as Applications and Reviews read a release
# (AttilaTheFun/applications' docs/RELEASE_ASSETS.md):
# Visor-<version>-<platform>.<ext> and builds.json, in <out>, for
# tools/ci/attach_release.sh. As isomer's tools/ci/sign_builds.sh.
#
#   tools/ci/sign_builds.sh --variant Alpha|Production --out <dir>
#       [--ipa-kind development|production] [--dmg] [--android-pin <sha256>] <package>…
#
# - .ipa (the iPhone and iPad app, a device build signed ad hoc,
#   --config=ci_device): apple_sign.sh --ipa-kind (development for an Alpha,
#   production for a release: ad hoc, else enterprise, else development
#   profiles), with APPLE_DEVELOPMENT_P12, APPLE_DEVELOPMENT_PASSWORD (empty
#   or unset: a .p12 with no password) and APPLE_PROFILES;
# - .zip (Visor.app, its Linux programs sealed in; Visor Disk Utility.app):
#   apple_sign.sh, Developer ID, notarized and stapled, with --dmg Visor's
#   disk image too (Visor.app's alone), with
#   APPLE_DEVELOPER_ID_P12, APPLE_DEVELOPER_ID_PASSWORD, APPLE_NOTARY_KEY,
#   APPLE_NOTARY_KEY_ID, APPLE_NOTARY_ISSUER and APPLE_PROFILES (its
#   Developer ID profile: Visor.app asks for push and the app group; Visor
#   Disk Utility needs none). Each Mac
#   app's assets go by its own name (mac_app_name): Visor-<version>-macos.zip
#   and Visor-Disk-Utility-<version>-macos.zip, each with its own
#   builds.json line and icon (Visor-<version>-icon.png,
#   Visor-Disk-Utility-<version>-icon.png), which Shireworks' Applications
#   tab is drawn from;
# - .apk: android_sign.sh with Visor's release key (`visor`), its
#   certificate pinned (--android-pin, the workflow's VISOR_ANDROID_PIN),
#   with ANDROID_SIGNING_KEYSTORE and ANDROID_SIGNING_PASSWORD; the JDK
#   Visor's Bazel runs Java with (rules_java's remotejdk_17) and
#   @android_build_tools' apksigner.jar, never the image's, and its
#   builds.json line read with that build-tools' aapt2. On x86_64 Linux
#   alone: the build tools Bazel has for Linux are x86_64. An
#   *_unsigned.apk beside it (Isomer's APK rule leaves one) is passed over.
#
# --variant is what the builds are: an Alpha (`--config=alpha`) or a
# release's Production build (`--config=prod`, built from its tag: nothing
# is stamped Production here). Each Apple package's BuildVariant must be
# it, and its version the first's (every Info.plist stamped alike), or
# nothing is signed. APPLE_PROFILES may be a gzipped .tar (GitHub
# caps a secret at 48 KB), with APPLE_PROFILES_2 … _9 beside it.
#
# A platform's package whose keys aren't all set fails the job: Visor's
# `release` environment holds them all, and a proposal or a release
# missing a platform would hide it from Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI="$ROOT/tools/ci"
fail() { echo "sign_builds: $*" >&2; exit 1; }
usage="usage: tools/ci/sign_builds.sh --variant Alpha|Production --out <dir> [--ipa-kind development|production] [--dmg] [--android-pin <sha256>] <package>…"
APP=Visor
ANDROID_KEY=visor

# The name a Mac app's assets go by, by its bundle id: Visor's for
# Visor.app (Visor-<version>-macos.zip, beside Visor's iPhone and Android
# apps), and Visor Disk Utility's own for it, a separate app that
# Applications offers on a line of its own
# (Visor-Disk-Utility-<version>-macos.zip). Any other Mac app isn't one this
# repository releases (the Mac client app, com.LoganShire.VisorClient.macOS,
# retired: Logan, 24 Nov 2026), and fails the signing.
mac_app_name() {
    case "$1" in
        com.LoganShire.Visor) echo "$APP" ;;
        com.LoganShire.Visor.DiskUtility) echo "Visor Disk Utility" ;;
        *) return 1 ;;
    esac
}

# The bundle ids a build takes the place of, for Applications (builds.json's
# "replaces", tools/ci/release_assets.sh): Visor.app on a Mac the retired
# Mac client app (Logan, 24 Nov 2026), whose install it's offered in place
# of.
release_asset_replaces() {
    case "$1:$2" in
        com.LoganShire.Visor:macos) echo '["com.LoganShire.VisorClient.macOS"]' ;;
    esac
}

variant="" out="" ipa_kind="development" dmg="" android_pin=""
packages=()
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) variant="${2:?}"; shift 2 ;;
        --out) out="${2:?}"; shift 2 ;;
        --ipa-kind) ipa_kind="${2:?}"; shift 2 ;;
        --dmg) dmg=1; shift ;;
        --android-pin) android_pin="${2:?}"; shift 2 ;;
        -*) fail "unknown option $1; $usage" ;;
        *_unsigned.apk) shift ;;
        *) packages+=("$1"); shift ;;
    esac
done

# The keys, taken out of the environment before anything else runs: each
# value kept in an unexported variable of this shell (secret_<NAME>) and its
# NAME unset, so no child (Bazel and its server, which keeps the environment
# it started with, Python, aapt2, curl) ever has them. A signer gets the
# keys it needs alone, exported in a subshell of its own by `export`, a
# builtin (with_secrets): no value is ever a process's argument, and nothing
# here prints one or runs under `set -x`.
SECRETS=(ANDROID_SIGNING_KEYSTORE ANDROID_SIGNING_PASSWORD APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_PASSWORD
         APPLE_NOTARY_KEY APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER APPLE_DEVELOPMENT_P12 APPLE_DEVELOPMENT_PASSWORD
         APPLE_PROFILES APPLE_PROFILES_2 APPLE_PROFILES_3 APPLE_PROFILES_4 APPLE_PROFILES_5 APPLE_PROFILES_6
         APPLE_PROFILES_7 APPLE_PROFILES_8 APPLE_PROFILES_9)
set +x
for name in "${SECRETS[@]}"; do
    printf -v "secret_$name" '%s' "${!name:-}"
    unset "$name"
done

[ -n "$out" ] && [ ${#packages[@]} -gt 0 ] || fail "$usage"
case "$variant" in Alpha | Production) ;; *) fail "--variant is Alpha or Production" ;; esac
case "$ipa_kind" in development | production) ;; *) fail "--ipa-kind is development or production" ;; esac
mkdir -p "$out"
out="$(cd "$out" && pwd)"
# shellcheck source=tools/ci/release_assets.sh
. "$CI/release_assets.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ipas=() zips=() apks=()
for package in "${packages[@]}"; do
    [ -f "$package" ] || fail "no such file: $package"
    package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"
    case "$package" in
        *.ipa) ipas+=("$package") ;;
        *.zip) zips+=("$package") ;;
        *.apk) apks+=("$package") ;;
        *) fail "$(basename "$package") is not an .ipa, a Mac app's .zip or an .apk" ;;
    esac
done

# Whether every named key was set, else the first that wasn't.
missing() {
    local name kept
    for name in "$@"; do
        kept="secret_$name"
        [ -n "${!kept}" ] || { echo "$name"; return 0; }
    done
    return 1
}
# A signer run with the named keys alone in its environment:
#   with_secrets <NAME>… -- <command>…
with_secrets() {
    local keep=()
    while [ "$1" != -- ]; do keep+=("$1"); shift; done
    shift
    (
        for name in "${keep[@]}"; do
            kept="secret_$name"
            [ -z "${!kept}" ] || export "$name=${!kept}"
        done
        exec "$@"
    )
}
# Each Apple package is the variant asked for (its Info.plist's
# BuildVariant), of one version, and each Mac app one released here,
# before anything is signed. Visor.app's .zip (its disk image's, with
# --dmg) apart from any other Mac app's.
version="" visor_zips=() other_zips=()
for package in ${ipas[@]+"${ipas[@]}"} ${zips[@]+"${zips[@]}"}; do
    description="$(release_asset_describe "$package")" || fail "$(basename "$package") was not read"
    built="$(sed -n 5p <<< "$description")"
    [ "$built" = "$variant" ] || fail "$(basename "$package") is a build of variant \"$built\", not $variant"
    stamped="$(sed -n 3p <<< "$description")"
    [ -n "$version" ] || version="$stamped"
    [ "$stamped" = "$version" ] || fail "$(basename "$package") is version \"$stamped\", not $version: stamp every Info.plist alike"
    case "$package" in
        *.zip)
            bundle="$(sed -n 1p <<< "$description")"
            name="$(mac_app_name "$bundle")" || fail "$(basename "$package") is $bundle, not a Mac app released here"
            if [ "$name" = "$APP" ]; then visor_zips+=("$package"); else other_zips+=("$package"); fi
            ;;
    esac
done
PROFILES=(APPLE_PROFILES APPLE_PROFILES_2 APPLE_PROFILES_3 APPLE_PROFILES_4 APPLE_PROFILES_5 APPLE_PROFILES_6
          APPLE_PROFILES_7 APPLE_PROFILES_8 APPLE_PROFILES_9)

if [ ${#ipas[@]} -gt 0 ]; then
    # Its .p12's password may be empty (a .p12 exported with none), passed
    # on as unset, which apple_sign.sh takes for no password.
    if name="$(missing APPLE_DEVELOPMENT_P12 APPLE_PROFILES)"; then
        fail "the iPhone app can't be signed: $name isn't set in the job's environment"
    fi
    with_secrets APPLE_DEVELOPMENT_P12 APPLE_DEVELOPMENT_PASSWORD "${PROFILES[@]}" -- \
        "$CI/apple_sign.sh" --key-from-env --ipa-kind "$ipa_kind" --out "$work/signed-ios" "${ipas[@]}"
    for package in "${ipas[@]}"; do
        release_asset_file "$work/signed-ios/$(basename "$package")" "$out" "$APP"
    done
fi

if [ ${#zips[@]} -gt 0 ]; then
    if name="$(missing APPLE_DEVELOPER_ID_P12 APPLE_NOTARY_KEY APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER APPLE_PROFILES)"; then
        fail "the Mac app can't be signed: $name isn't set in the job's environment"
    fi
    # Visor.app with its disk image (--dmg), any other Mac app without one.
    if [ ${#visor_zips[@]} -gt 0 ]; then
        with_secrets APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_PASSWORD APPLE_NOTARY_KEY \
            APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER "${PROFILES[@]}" -- \
            "$CI/apple_sign.sh" --key-from-env ${dmg:+--dmg} --out "$work/signed-mac" "${visor_zips[@]}"
    fi
    if [ ${#other_zips[@]} -gt 0 ]; then
        with_secrets APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_PASSWORD APPLE_NOTARY_KEY \
            APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER "${PROFILES[@]}" -- \
            "$CI/apple_sign.sh" --key-from-env --out "$work/signed-mac" "${other_zips[@]}"
    fi
    for package in ${visor_zips[@]+"${visor_zips[@]}"}; do
        signed="$work/signed-mac/$(basename "$package")"
        release_asset_file "$signed" "$out" "$APP"
        # The disk image, described by its app's .zip.
        [ -z "$dmg" ] || release_asset_file "${signed%.zip}.dmg" "$out" "$APP" "$signed"
    done
    for package in ${other_zips[@]+"${other_zips[@]}"}; do
        signed="$work/signed-mac/$(basename "$package")"
        release_asset_file "$signed" "$out" "$(mac_app_name "$(release_asset_describe "$signed" | sed -n 1p)")"
    done
fi

if [ ${#apks[@]} -gt 0 ]; then
    if name="$(missing ANDROID_SIGNING_KEYSTORE ANDROID_SIGNING_PASSWORD)"; then
        fail "the Android app can't be signed: $name isn't set in the job's environment"
    fi
    [ -n "$android_pin" ] || fail "an .apk takes --android-pin"
    # The repository's own pinned JDK and build tools, by Bazel's own paths:
    # Bazel (and the repository rules it runs) started after the keys left
    # the environment (above), so they never see one.
    runtime=@rules_java//toolchains:current_java_runtime
    tools=(@android_build_tools//:lib/apksigner.jar @android_build_tools//:aapt2)
    (cd "$ROOT" && bazel build "$runtime" "${tools[@]}" > "$work/tools.log" 2>&1) \
        || { tail -30 "$work/tools.log" >&2; fail "the JDK and build tools didn't fetch"; }
    base="$(cd "$ROOT" && bazel info output_base 2> /dev/null)"
    files() { (cd "$ROOT" && bazel cquery "$1" --output=files 2> /dev/null); }
    java="$base/$(files "$runtime" | sed -n '\#/bin/java$#{p;q;}')"
    apksigner="$base/$(files @android_build_tools//:lib/apksigner.jar | head -1)"
    aapt2="$base/$(files @android_build_tools//:aapt2 | head -1)"
    [ -x "$java" ] && [ -f "$apksigner" ] && [ -x "$aapt2" ] || fail "no JDK or build tools at $java, $apksigner, $aapt2"
    for package in "${apks[@]}"; do
        signed="$work/signed-android/$(basename "$package")"
        with_secrets ANDROID_SIGNING_KEYSTORE ANDROID_SIGNING_PASSWORD -- \
            "$CI/android_sign.sh" --key-from-env --app "$ANDROID_KEY" --pin "$android_pin" \
            --java "$java" --apksigner "$apksigner" "$package" "$signed"
        # Its line as Shireworks' signing service answered for an APK
        # (release_asset_answer_describe): the package, its version and
        # versionCode and its label, from its manifest (aapt2), the variant
        # the job's.
        "$aapt2" dump badging "$signed" > "$work/badging.txt" || fail "aapt2 doesn't read $(basename "$signed")"
        python3 -I - "$work/badging.txt" "$variant" > "$work/answer.json" << 'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
def field(pattern):
    found = re.search(pattern, text, re.M)
    return found.group(1) if found else ""
package = field(r"^package: name='([^']*)'")
if not package:
    sys.exit("sign_builds: aapt2 names no package")
build = {"platform": "android", "name": field(r"^application-label:'([^']*)'") or package,
         "version": field(r"versionName='([^']*)'"), "buildNumber": field(r"versionCode='([^']*)'"),
         "variant": sys.argv[2], "urlSchemes": []}
json.dump({"bundleID": package, "channel": "production" if sys.argv[2] == "Production" else "beta", "build": build}, sys.stdout)
PY
        release_asset_file "$signed" "$out" "$APP" "$work/answer.json"
    done
fi

echo "sign_builds: into $out:"
ls -l "$out"
