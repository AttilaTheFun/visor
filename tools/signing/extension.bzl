"""The builder's own signing values, from the environment, not the repo.

`@visor_signing//:signing.bzl` defines:

- TEAM_ID: the Apple team to sign device builds with, from VISOR_TEAM_ID,
  or a placeholder.
- UPDATE_APP_GROUP: the app group the apps share with the distributor's
  Applications (UpdateKit's `UpdateKitAppGroup`), from
  VISOR_UPDATE_APP_GROUP, or "" for none: then no build names a group, in
  its Info.plist or its entitlements, and UpdateKit does nothing.
- UPDATE_APPLICATIONS_BUNDLE_IDS: on a Mac, the bundle ids of Applications
  to ask to install an update (`UpdateKitApplicationsBundleIDs`), from
  VISOR_UPDATE_APPLICATIONS_BUNDLE_IDS, comma-separated, or none.

Set them for your builds in a `.bazelrc.user` at the workspace root (it is
not checked in); CI's distribution builds set the update ones from the
repository's variables:

    common --repo_env=VISOR_TEAM_ID=<your team id>
    common --repo_env=VISOR_UPDATE_APP_GROUP=<group.…>
    common --repo_env=VISOR_UPDATE_APPLICATIONS_BUNDLE_IDS=<id>,<id>

Simulator and Mac builds need nothing; an iPhone build needs your team's
development profile (tools/mint_profile makes it), and with an app group,
a profile whose App ID has it.
"""

def _signing_impl(rctx):
    team = rctx.getenv("VISOR_TEAM_ID", "YOUR_TEAM_ID") or "YOUR_TEAM_ID"
    group = (rctx.getenv("VISOR_UPDATE_APP_GROUP", "") or "").strip()
    ids = [i.strip() for i in (rctx.getenv("VISOR_UPDATE_APPLICATIONS_BUNDLE_IDS", "") or "").split(",") if i.strip()]
    rctx.file("BUILD.bazel", 'exports_files(["signing.bzl"])\n')
    rctx.file("signing.bzl", "\n".join([
        "TEAM_ID = %s" % repr(team),
        "UPDATE_APP_GROUP = %s" % repr(group),
        "UPDATE_APPLICATIONS_BUNDLE_IDS = %s" % repr(ids),
        "",
    ]))

_signing = repository_rule(implementation = _signing_impl)

def _extension_impl(_mctx):
    _signing(name = "visor_signing")

signing = module_extension(implementation = _extension_impl)
