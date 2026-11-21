"""protoc, as the proto toolchain resolves it: protobuf's prebuilt one for
the machine that runs it (its prefer_prebuilt_protoc, on by default), not
one compiled from source."""

_PROTO_TOOLCHAIN = "@protobuf//bazel/private:proto_toolchain_type"

def _resolved_protoc_impl(ctx):
    protoc = ctx.toolchains[_PROTO_TOOLCHAIN].proto.proto_compiler.executable
    linked = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = linked, target_file = protoc, is_executable = True)
    return [DefaultInfo(
        executable = linked,
        files = depset([linked]),
        runfiles = ctx.runfiles(files = [linked, protoc]),
    )]

resolved_protoc = rule(
    implementation = _resolved_protoc_impl,
    executable = True,
    toolchains = [_PROTO_TOOLCHAIN],
    doc = "The resolved proto toolchain's protoc, as an executable a tool can run.",
)
