"""The builder's own signing values, from the environment, not the repo.

`@visor_signing//:signing.bzl` defines TEAM_ID: the Apple team to sign
device builds with, from VISOR_TEAM_ID, or a placeholder. Set it for your
builds in a `.bazelrc.user` at the workspace root (it is not checked in):

    common --repo_env=VISOR_TEAM_ID=<your team id>

Simulator and Mac builds need nothing; an iPhone build needs your team's
development profile (tools/mint_profile makes it).
"""

def _signing_impl(rctx):
    team = rctx.getenv("VISOR_TEAM_ID", "YOUR_TEAM_ID") or "YOUR_TEAM_ID"
    rctx.file("BUILD.bazel", 'exports_files(["signing.bzl"])\n')
    rctx.file("signing.bzl", 'TEAM_ID = "%s"\n' % team)

_signing = repository_rule(implementation = _signing_impl)

def _extension_impl(_mctx):
    _signing(name = "visor_signing")

signing = module_extension(implementation = _extension_impl)
