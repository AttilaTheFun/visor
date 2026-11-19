// relay-client on its own (RelayClientCommand, in VisorRelayClient), for
// Bazel: the static program that ships is visor-server run by this name
// (tools/linux_programs.sh).

import Foundation
import VisorRelayClient

exit(await RelayClientCommand.main(CommandLine.arguments))
