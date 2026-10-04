// visor-server on Linux: the command-line server, given Linux's system.

import Foundation
import VisorServerCLI
import VisorServerLinux

let status = await ServerCommand(system: LinuxSystem()).main()
exit(status)
