import VisorContainerHost

// A debug build's secrets: in a file of each container server's folder
// (tools/secrets).
let hostSecrets: ContainerHostCommand.Secrets = ContainerHostCommand.fileSecrets
