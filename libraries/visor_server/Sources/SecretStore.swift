// What the server keeps secret — its password — in the keychain, as a
// generic password under the app's bundle id. The app that wrote it reads
// it without asking, as long as it is signed the same way each build (a
// stable signature, not ad hoc). Tests use a store of their own.

import Foundation
import Security

protocol SecretStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}
