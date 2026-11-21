// `Visor admin-token`: the admin token printed to standard output, for a
// script (`curl -H "Authorization: Bearer $(/Applications/Visor.app/Contents/MacOS/Visor
// admin-token)" …`), so no `.zshrc` need export it. Read from the keychain
// as every process of Visor.app's reads the server's items (MacSecrets:
// the data-protection keychain under the app's own group), never from a
// file. Only a token made or rotated since 0.65 is kept (AdminToken's
// `keepingToken`); for one from before, it says to rotate it once.

import Foundation
import VisorServer

@MainActor
enum MacAdminTokenCommand {
    /// Prints the token and ends when `arguments` ask for it; returns
    /// otherwise.
    static func handle(_ arguments: [String]) {
        guard Array(arguments.dropFirst()) == ["admin-token"] else { return }
        // Where Visor's things are, nothing moved; the server's secrets.
        MacServer.prepare(runsServer: false, client: false)
        guard let token = ServerPlatform.current.secrets.get(VisorServer.adminTokenSecret), !token.isEmpty else {
            FileHandle.standardError.write(Data(("Visor: no admin token is kept to print. One made before 0.65 isn't: rotate it once "
                + "(POST /api/admin-token/rotate, or Reset Admin Token… in the menu), or make one (Settings › Create Admin Token…), and it's kept from then.\n").utf8))
            exit(1)
        }
        print(token)
        exit(0)
    }
}
