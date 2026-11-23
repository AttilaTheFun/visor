"""What a build of Logan's says of the sign-in his apps share: ShakeKit's
`GitHubShared…` keys in its Info.plist, and the shared keychain group in
its entitlements (shake_kit's GitHubAuth, GitHubSharedSignIn: one OAuth
App's token, kept in a keychain group the apps all carry and renewed under
a lock in an app group's container they all carry too).

    load("//tools/shared_sign_in:defs.bzl", "shared_sign_in_infoplist")

    shared_sign_in_infoplist(name = "shared_sign_in_plist")

A build says it only when the builder has all of it (extension.bzl's
CLIENT_ID, tools/team_id's TEAM_ID_REAL, and tools/signing's
UPDATE_APP_GROUP, the lock's group), which CI's builds to publish alone
have; and the apps take it in
those builds alone (their `ci_signed`/`ci_device` selects), so a build to
run here, and anyone else's, carries none of it. It is ShakeKit's only
sign-in (shake_kit 0.3: signed in to Shireworks on the same phone or
computer), so there ShakeKit, on by its Info.plist, reports nothing.

An entitlements template takes the shared keychain group at the line
`<!-- SHARED_SIGN_IN_KEYCHAIN_GROUP -->`, in its `keychain-access-groups`
array: `<string><prefix>com.LoganShire.github</string>`, or nothing
(`shared_keychain_group`; tools/app_groups' `app_group_entitlements` fills
it in, with the builder's team as the prefix).
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@visor_shared_sign_in//:values.bzl", "CLIENT_ID")
load("@visor_signing//:signing.bzl", "UPDATE_APP_GROUP")
load("//tools/team_id:defs.bzl", "TEAM_ID_REAL")

# The template's line the shared keychain group takes.
KEYCHAIN_PLACEHOLDER = "<!-- SHARED_SIGN_IN_KEYCHAIN_GROUP -->"

# The shared keychain group's name after the team's prefix, and the keychain
# service the token is kept under: Shireworks' and the rest of Logan's apps'.
KEYCHAIN_NAME = "com.LoganShire.github"

def _xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def shared_sign_in():
    """Whether the builder has the shared sign-in: its client id, its team
    and the app group of its lock."""
    return bool(CLIENT_ID and TEAM_ID_REAL and UPDATE_APP_GROUP)

def shared_keychain_group(prefix):
    """The shared keychain group as an entry of `keychain-access-groups`,
    `prefix` its team's (`$(AppIdentifierPrefix)`, or the team and a dot),
    or "" without the shared sign-in."""
    if not shared_sign_in():
        return ""
    return "<string>%s%s</string>" % (_xml(prefix), KEYCHAIN_NAME)

def shared_sign_in_infoplist(name, **kwargs):
    """An Info.plist fragment: GitHubSharedClientID, GitHubSharedKeychainGroup,
    GitHubSharedLockGroup and GitHubSharedKeychainService, or nothing."""
    entries = []
    if shared_sign_in():
        for key, value in [
            ("GitHubSharedClientID", CLIENT_ID),
            ("GitHubSharedKeychainGroup", TEAM_ID_REAL + "." + KEYCHAIN_NAME),
            ("GitHubSharedLockGroup", UPDATE_APP_GROUP),
            ("GitHubSharedKeychainService", KEYCHAIN_NAME),
        ]:
            entries += ["\t<key>%s</key>" % key, "\t<string>%s</string>" % _xml(value)]
    write_file(
        name = name,
        out = name + ".plist",
        content = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
            '<plist version="1.0">',
            "<dict>",
        ] + entries + [
            "</dict>",
            "</plist>",
            "",
        ],
        **kwargs
    )

def shared_sign_in_entitlements(name, template, substitutions = {}, **kwargs):
    """`template` with its KEYCHAIN_PLACEHOLDER line the shared keychain
    group (its prefix left `$(AppIdentifierPrefix)`, for a build whose
    profile gives it: an iPhone's), and `substitutions`."""
    all_substitutions = dict(substitutions)
    all_substitutions[KEYCHAIN_PLACEHOLDER] = shared_keychain_group("$(AppIdentifierPrefix)")
    expand_template(
        name = name,
        out = name + ".entitlements",
        template = template,
        substitutions = all_substitutions,
        **kwargs
    )
