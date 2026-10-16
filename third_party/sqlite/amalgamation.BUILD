load("@rules_cc//cc:cc_library.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

# SQLite's amalgamation, for every host without a system SQLite: built with
# the full-text index the message cache searches by (FTS5), and without
# what it never uses (loading extensions).
cc_library(
    name = "sqlite3",
    srcs = ["sqlite3.c"],
    hdrs = ["sqlite3.h"],
    includes = ["."],
    local_defines = [
        "SQLITE_ENABLE_FTS5",
        "SQLITE_OMIT_LOAD_EXTENSION",
        "SQLITE_DQS=0",
        "SQLITE_DEFAULT_MEMSTATUS=0",
    ],
    linkopts = select({
        "@platforms//os:linux": ["-lpthread", "-lm"],
        "@platforms//os:android": ["-lm"],
        "//conditions:default": [],
    }),
)
