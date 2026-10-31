import VisorContainerHost
import VisorContainerHostApple

// A notarized build's secrets: in the keychain, by container server
// (tools/secrets).
let hostSecrets: ContainerHostCommand.Secrets = { _, spec in KeychainHostSecrets(server: spec.id) }
