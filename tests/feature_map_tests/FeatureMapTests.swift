// FEATURE_MAP.md walked through Isomer's driver (isomer's
// shared/wire/headless.proto, IsomerHeadless's HeadlessApp): every screen
// reached and recognised, every solid edge taken and its destination
// checked, on the client headless in a Linux container
// (//applications/visor_headless, --config=headless). The suites nested
// here (one a file) take one part of the map each; FeatureMapGapTests
// names what can't be driven yet, and why.
//
// One test at a time: each launches a client of its own, and the same
// bodies drive a headful client (a launcher's, VisorLaunch), which is one
// app at a time.

import Testing

@Suite(.serialized)
enum FeatureMapTests {}
