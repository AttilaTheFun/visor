// visor-server on Windows: the command-line server, given Windows's system.

import Foundation
import VisorServerCLI
import VisorServerWindows

let status = await ServerCommand(system: WindowsSystem()).main()
exit(status)
