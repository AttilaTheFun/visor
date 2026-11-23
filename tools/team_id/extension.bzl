"""Visor's one team id, from the build's `VISOR_TEAM_ID` repo_env.

`@visor_team_id//:team_id.bzl` defines TEAM_ID_REAL: the Apple team id the
build is made for (`--repo_env=VISOR_TEAM_ID=<team>`: a builder's own
.bazelrc.user, or CI's Apple jobs, from the repository's VISOR_TEAM_ID
variable), or "" when it's unset or tools/signing's placeholder. It is
never in the repository. Load it through //tools/team_id:defs.bzl.
"""

_PLACEHOLDER = "YOUR_TEAM_ID"

def _team_id_impl(rctx):
    team = (rctx.getenv("VISOR_TEAM_ID", "") or "").strip()
    if team == _PLACEHOLDER:
        team = ""
    if team and not (len(team) == 10 and team.isalnum() and team.upper() == team):
        fail("VISOR_TEAM_ID must be an Apple team id: ten capital letters and digits.")
    rctx.file("BUILD.bazel", 'exports_files(["team_id.bzl"])\n')
    rctx.file("team_id.bzl", "TEAM_ID_REAL = %s\n" % repr(team))

_team_id = repository_rule(implementation = _team_id_impl)

def _extension_impl(_mctx):
    _team_id(name = "visor_team_id")

team_id = module_extension(implementation = _extension_impl)
