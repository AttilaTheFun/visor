// //tools/e2e/container: the Sessions container booted for real on a
// throwaway data folder, checked, stopped and deleted (ContainerCheck).

import Foundation

SelfSigning.ensure()
let options = ContainerCheckOptions.parse(Array(CommandLine.arguments.dropFirst()))
exit(await ContainerCheck(options: options).run())
