"""`wasm_resource`: a wasm reactor bundled as a resource of an Apple app.

A reactor listed in an `ios_application`'s `resources` is built in the app's
configuration: Apple platform iOS, at the app's minimum OS. That setting means
nothing to wasm code, but the SwiftPM rules check it, and a package declaring
a newer iOS than the app's fails the build of an iOS 16 app. This builds the reactor in the configuration a top-level
build gives it (as the web's is), whatever app embeds it.
"""

# What a top-level build of a reactor has (`bazel build <reactor>`, with this
# repository's .bazelrc): the settings an Apple app's transition changes, put
# back. A partial reset (only apple_platform_type) leaves a hybrid
# configuration in which the SwiftPM rules move AgentUI into one of their own,
# and swift_ffi's SwiftABI module map is then built twice.
_TOP_LEVEL = {
    "//command_line_option:platforms": ["@bazel_tools//tools:host_platform"],
    "//command_line_option:cpu": "darwin_arm64",
    "//command_line_option:apple_platform_type": "macos",
    "//command_line_option:apple_split_cpu": "",
    "//command_line_option:ios_minimum_os": "18.0",
    "//command_line_option:ios_multi_cpus": [],
    "//command_line_option:macos_cpus": [],
    "//command_line_option:macos_minimum_os": "15.0",
    "//command_line_option:minimum_os_version": "15.0",
    "//command_line_option:tvos_minimum_os": None,
    "//command_line_option:watchos_minimum_os": None,
    "//command_line_option:compiler": None,
    "//command_line_option:fission": [],
    "//command_line_option:grte_top": None,
    # Optimized, whatever the app's mode: an unoptimized reactor overflows
    # WAMR's interpreter stack (a plain `bazel build` of the app is
    # fastbuild).
    "//command_line_option:compilation_mode": "opt",
}

def _as_top_level_impl(_settings, _attr):
    return _TOP_LEVEL

_as_top_level = transition(
    implementation = _as_top_level_impl,
    inputs = [],
    outputs = _TOP_LEVEL.keys(),
)

def _wasm_resource_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [src[DefaultInfo].files for src in ctx.attr.srcs]))]

wasm_resource = rule(
    implementation = _wasm_resource_impl,
    attrs = {
        "srcs": attr.label_list(cfg = _as_top_level, allow_files = True, mandatory = True),
    },
    doc = "Republishes wasm `srcs` built as a top-level build would, for an Apple app's resources.",
)

# The threaded reactor's configuration: a top-level build's, without
# FoundationInternationalization. Its ICU is the Swift SDK's prebuilt
# library, which the wasi-threads SDK does not carry (and a library built
# without atomics cannot link into a shared memory), so a threaded reactor
# formats dates and numbers with FoundationEssentials alone.
_THREADS_TOP_LEVEL = dict(_TOP_LEVEL)
_THREADS_TOP_LEVEL["@isomer//foundation:internationalization"] = False

def _as_threads_top_level_impl(_settings, _attr):
    return _THREADS_TOP_LEVEL

_as_threads_top_level = transition(
    implementation = _as_threads_top_level_impl,
    inputs = [],
    outputs = _THREADS_TOP_LEVEL.keys(),
)

threads_wasm_resource = rule(
    implementation = _wasm_resource_impl,
    attrs = {
        "srcs": attr.label_list(cfg = _as_threads_top_level, allow_files = True, mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "`wasm_resource` for a threaded reactor: built as a top-level build would, without FoundationInternationalization.",
)
