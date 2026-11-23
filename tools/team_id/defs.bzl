"""Visor's one team id (extension.bzl): what every target that needs the
real Apple team id loads, never a value in the repository.

    load("//tools/team_id:defs.bzl", "TEAM_ID_REAL")

TEAM_ID_REAL is "" when the build has no VISOR_TEAM_ID (or the
placeholder): Visor Disk Utility's root check then refuses in an optimized
build (ConversionChecker.team).
"""

load("@visor_team_id//:team_id.bzl", _TEAM_ID_REAL = "TEAM_ID_REAL")

TEAM_ID_REAL = _TEAM_ID_REAL
