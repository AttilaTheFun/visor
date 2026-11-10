"""What a build says of the app group it shares with Applications, from
the builder's own values (extension.bzl), so the repository names none.

    load("//tools/signing:defs.bzl", "update_entitlements", "update_infoplist")

    update_infoplist(name = "update_plist")   # an Info.plist fragment
    update_entitlements(name = "app_entitlements", template = "app.entitlements")

A template is an entitlements plist with the line `<!-- UPDATE_APP_GROUP -->`
where the group goes: `com.apple.security.application-groups` with it, or
nothing when no group is set. With no group the plist fragment is empty, and
UpdateKit does nothing (its README, "The app group").
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@visor_signing//:signing.bzl", "UPDATE_APPLICATIONS_BUNDLE_IDS", "UPDATE_APP_GROUP")

PLACEHOLDER = "<!-- UPDATE_APP_GROUP -->"

def _xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def update_group_entitlement():
    """The app group's entitlement as plist lines, or "" with none. The
    first line takes the placeholder's place, and its indent (a tab)."""
    if not UPDATE_APP_GROUP:
        return ""
    return "\n".join([
        "<key>com.apple.security.application-groups</key>",
        "\t<array>",
        "\t\t<string>%s</string>" % _xml(UPDATE_APP_GROUP),
        "\t</array>",
    ])

def update_infoplist(name, **kwargs):
    """An Info.plist fragment: UpdateKitAppGroup and, with any,
    UpdateKitApplicationsBundleIDs."""
    entries = []
    if UPDATE_APP_GROUP:
        entries += ["\t<key>UpdateKitAppGroup</key>", "\t<string>%s</string>" % _xml(UPDATE_APP_GROUP)]
        if UPDATE_APPLICATIONS_BUNDLE_IDS:
            entries += ["\t<key>UpdateKitApplicationsBundleIDs</key>", "\t<array>"]
            entries += ["\t\t<string>%s</string>" % _xml(i) for i in UPDATE_APPLICATIONS_BUNDLE_IDS]
            entries += ["\t</array>"]
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

def update_entitlements(name, template, **kwargs):
    """`template` with its PLACEHOLDER line given the app group, or removed."""
    expand_template(
        name = name,
        out = name + ".entitlements",
        template = template,
        substitutions = {PLACEHOLDER: update_group_entitlement()},
        **kwargs
    )
