"""The sign-in Logan's apps share (ShakeKit's `GitHubShared…` keys), from
the builder's environment, never the repository: it is public, and the
OAuth App's client id is not.

`@visor_shared_sign_in//:values.bzl` defines:

- CLIENT_ID: the shared OAuth App's client id, from
  VISOR_GITHUB_SHARED_CLIENT_ID, or "" for none.
- TEAM_ID: the Apple team whose keychain group holds the shared token
  (`<team>.com.LoganShire.github`), from VISOR_GITHUB_SHARED_TEAM_ID, or
  VISOR_TEAM_ID when that names one, or "". An Info.plist names the group
  in full, so this is the team itself: CI's builds are otherwise signed
  with a placeholder team (tools/signing), which its signing makes the
  profile's in the entitlements alone.

Both, and the builder's UPDATE_APP_GROUP (tools/signing: the app group the
renewal lock is kept in), or no build says anything of the shared sign-in
(defs.bzl). CI's builds to publish set them from the repository's secrets:

    common --repo_env=VISOR_GITHUB_SHARED_CLIENT_ID=<client id>
    common --repo_env=VISOR_GITHUB_SHARED_TEAM_ID=<team id>

A value that isn't one fails the build without saying it.
"""

def _value(rctx, name, allowed):
    text = (rctx.getenv(name, "") or "").strip()
    for character in text.elems():
        if character not in allowed:
            fail("%s isn't a %s: it has a character none has" % (name, "client id" if "CLIENT" in name else "team id"))
    return text

_CLIENT_ID = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."
_TEAM_ID = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

def _shared_sign_in_impl(rctx):
    client = _value(rctx, "VISOR_GITHUB_SHARED_CLIENT_ID", _CLIENT_ID)
    team = _value(rctx, "VISOR_GITHUB_SHARED_TEAM_ID", _TEAM_ID)
    if not team:
        # The builder's own team, unless it's tools/signing's placeholder.
        builder = (rctx.getenv("VISOR_TEAM_ID", "") or "").strip()
        if builder and all([c in _TEAM_ID for c in builder.elems()]):
            team = builder
    rctx.file("BUILD.bazel", 'exports_files(["values.bzl"])\n')
    rctx.file("values.bzl", "\n".join([
        "CLIENT_ID = %s" % repr(client),
        "TEAM_ID = %s" % repr(team),
        "",
    ]))

_shared_sign_in = repository_rule(implementation = _shared_sign_in_impl)

def _extension_impl(_mctx):
    _shared_sign_in(name = "visor_shared_sign_in")

shared_sign_in = module_extension(implementation = _extension_impl)
