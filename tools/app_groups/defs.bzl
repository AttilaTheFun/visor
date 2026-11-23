"""The app groups a Developer ID build of the Visor family asks for: the
Visor family's own, `group.com.LoganShire.Visor` (Visor.app, Visor Agent
Utility, Visor Disk Utility: presence, messaging, the sockets in its
container; docs/sandboxed.md), and the group shared with Shireworks
(UpdateKit's installed versions, the shared sign-in's lock), which is the
builder's own, UPDATE_APP_GROUP (tools/signing: CI's VISOR_UPDATE_APP_GROUP,
`group.com.LoganShire.Shireworks` from 23 Nov 2026, in place of
`group.com.LoganShire.Applications`).

    load("//tools/app_groups:defs.bzl", "app_group_entitlements")

    app_group_entitlements(name = "app_ci_entitlements", template = "app.ci.entitlements")

As tools/signing's `update_entitlements` with `team_prefix = True` (its
`$(AppIdentifierPrefix)` the builder's team, which CI's signing makes the
Developer ID profile's), but the template's `<!-- UPDATE_APP_GROUP -->` line
becomes `com.apple.security.application-groups` with every group: the
Visor family's first, then UPDATE_APP_GROUP when the builder has one. The
Developer ID profile must grant each (an entitlement the profile doesn't
grant fails signing, as Visor Disk Utility's did in 0.65.1).
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@visor_signing//:signing.bzl", "TEAM_ID", "UPDATE_APP_GROUP")
load("//tools/signing:defs.bzl", "PLACEHOLDER")

# The Visor family's app group (libraries/visor_disk_volumes' VisorPlaces).
VISOR_APP_GROUP = "group.com.LoganShire.Visor"

def _xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def app_groups(groups = [VISOR_APP_GROUP]):
    """`groups`, then the builder's UPDATE_APP_GROUP if it isn't among them."""
    return groups + ([UPDATE_APP_GROUP] if UPDATE_APP_GROUP and UPDATE_APP_GROUP not in groups else [])

def app_group_entitlement(groups = [VISOR_APP_GROUP]):
    """The application-groups entitlement as plist lines; its first line
    takes the placeholder's place, and its indent (a tab)."""
    return "\n".join(
        ["<key>com.apple.security.application-groups</key>", "\t<array>"] +
        ["\t\t<string>%s</string>" % _xml(group) for group in app_groups(groups)] +
        ["\t</array>"],
    )

def app_group_entitlements(name, template, groups = [VISOR_APP_GROUP], **kwargs):
    """`template` with its PLACEHOLDER line the app groups' entitlement, and
    its `$(AppIdentifierPrefix)` the builder's team."""
    expand_template(
        name = name,
        out = name + ".entitlements",
        template = template,
        substitutions = {
            PLACEHOLDER: app_group_entitlement(groups),
            "$(AppIdentifierPrefix)": _xml(TEAM_ID) + ".",
        },
        **kwargs
    )
