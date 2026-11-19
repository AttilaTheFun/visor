No ported tools, on purpose: MODULE.bazel's `ported_tools_archives` for
x86_64, the CPU rules_applecross stages Linux's ported tools for on any host
that isn't Linux. A Mac building with its toolchains (.bazelrc's
apple_cross_mac, CI's release Apple apps) never runs them (Xcode's own
bundle), and without this it would fetch them from where MODULE.bazel's
placeholder points, a Shireworks server, which GitHub's runners can't reach.
