// visor-server on a Mac, headless: the command-line server with the
// Mac's system, for a server a script or a sandbox starts (no menu bar
// app; `visor-server help` for its commands and options).

import Foundation
import VisorServerCLI
import VisorServerMac

let status = await ServerCommand(system: MacSystem()).main()
exit(status)
