"""The client id of the sign-in Logan's apps share (Shireworks Kit's
`GitHubSharedClientID`), from the builder's environment, never the
repository, which is public: the OAuth App's client id is kept private.

`@visor_shared_sign_in//:values.bzl` defines CLIENT_ID: the shared OAuth
App's client id, from VISOR_GITHUB_SHARED_CLIENT_ID, or "" for none.

With it, Visor's team (tools/team_id's TEAM_ID_REAL, from VISOR_TEAM_ID:
the shared keychain group is `<team>.com.LoganShire.github`, named in full
in an Info.plist) and the builder's UPDATE_APP_GROUP (tools/signing: the
app group the renewal lock is kept in), a build says it has the shared
sign-in (defs.bzl); without any of them it says nothing of it. CI's builds
to publish are made without them (a Nimbus macOS VM, which no secret
reaches): CI's signing stamps the same keys and keychain group into the
signed apps, from the repository's VISOR_GITHUB_SHARED_CLIENT_ID secret and
its VISOR_TEAM_ID variable (tools/ci/sign_builds.sh). A builder's own:

    common --repo_env=VISOR_GITHUB_SHARED_CLIENT_ID=<client id>

A value that isn't one fails the build without saying it.
"""

_CLIENT_ID = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."

def _shared_sign_in_impl(rctx):
    client = (rctx.getenv("VISOR_GITHUB_SHARED_CLIENT_ID", "") or "").strip()
    for character in client.elems():
        if character not in _CLIENT_ID:
            fail("VISOR_GITHUB_SHARED_CLIENT_ID isn't a client id: it has a character none has")
    rctx.file("BUILD.bazel", 'exports_files(["values.bzl"])\n')
    rctx.file("values.bzl", "CLIENT_ID = %s\n" % repr(client))

_shared_sign_in = repository_rule(implementation = _shared_sign_in_impl)

def _extension_impl(_mctx):
    _shared_sign_in(name = "visor_shared_sign_in")

shared_sign_in = module_extension(implementation = _extension_impl)
