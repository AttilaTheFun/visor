// The server as its owner's menu and Settings show it and change it, over
// REST (docs/protocol.md, "The server's own settings"): what Visor.app asks
// of its own server, in the app's process or the server agent's, the same
// way it asks of any other.
//
//   GET /api/settings        ServerControls: how it is reached and signed
//                            in to, what it is doing, its settings
//   PUT /api/settings        ServerControlsChange: the fields given set, the
//                            rest left; the same answer, as it is now (the
//                            container's CPUs and memory taken at its next
//                            start: VisorServer+ContainerResources)
//   GET /api/session-table   {text}: every session as a markdown table
//
// Each is an admin route, as every REST route is (authorized).

import Foundation
import VisorProtocol

extension VisorServer {
    /// `/api/settings`, by method.
    func restSettings(_ call: RESTCall) -> HTTPResponse {
        switch call.request.method {
        case "GET":
            return .json(controls.json.encoded())
        case "PUT":
            guard let fields = parseJSON(call.request.body) else { return HTTPResponse(400, Envelope.error("A JSON object is required").encoded()) }
            if let problem = apply(ServerControlsChange(json: fields)) { return HTTPResponse(400, Envelope.error(problem).encoded()) }
            return .json(controls.json.encoded())
        default:
            return HTTPResponse(404, "{\"error\":\"not found\"}")
        }
    }

    /// `GET /api/session-table`: the menu's Copy Session Table.
    func restSessionTable(_ call: RESTCall) -> HTTPResponse {
        .json(JSONValue.object(["type": .string("sessionTable"), "text": .string(sessionTable())]).encoded())
    }

    /// The server as its owner's menu and Settings show it.
    public var controls: ServerControls {
        var controls = ServerControls()
        controls.host = hostName
        controls.id = id
        controls.version = Self.version
        controls.port = Int(port)
        controls.password = password
        controls.listening = listening
        controls.lastError = lastError
        controls.updateNotice = updateNotice
        controls.reachableAddress = reachableAddress
        controls.codes = connectionCodes
        controls.clientCount = clientCount
        controls.servesTLS = servesTLS
        controls.sshPaths = sshPaths
        controls.settings = ServerControls.Settings(authentication: settings.authentication, lan: settings.lan, vpn: settings.vpn,
                                                    sshEnabled: settings.sshEnabled, proxyEnabled: settings.proxyEnabled,
                                                    publicAddress: settings.publicAddress, tlsIdentityPath: settings.tlsIdentityPath,
                                                    detachAgents: settings.detachAgents, clientsKeepMessages: settings.clientsKeepMessages,
                                                    containerEnabled: settings.container?.enabled ?? false,
                                                    containerImageDigest: settings.container?.imageDigest ?? "",
                                                    containerCPUs: settings.container?.cpus, containerMemoryGiB: settings.container?.memoryGiB,
                                                    containerIdleMinutes: settings.container?.idleMinutes ?? ContainerSettings.defaultIdleMinutes)
        controls.detachingSet = Self.detachingSet()
        let key = apnsKey
        controls.apnsKeyID = key.keyID
        controls.apnsTeamID = key.teamID
        controls.apnsConfigured = key.configured
        controls.pushDevices = pushDeviceCount
        controls.hasAdminToken = hasAdminToken
        controls.containerLimits = containerLimits
        return controls
    }

    /// A change of the owner's: the settings given set at once (one save,
    /// one listening again where how it listens changed), then the TLS
    /// identity's password, then the password. Nil when it was taken;
    /// otherwise why not, and nothing changed.
    public func apply(_ change: ServerControlsChange) -> String? {
        if let authentication = change.authentication, !["password", "none"].contains(authentication) {
            return "Clients show the password, or nothing"
        }
        let password = change.password?.trimmingCharacters(in: .whitespaces)
        if password?.isEmpty == true { return "A password is required." }
        var next = settings
        if let authentication = change.authentication { next.authentication = authentication }
        if let lan = change.lan { next.lan = lan }
        if let vpn = change.vpn { next.vpn = vpn }
        if let sshEnabled = change.sshEnabled { next.sshEnabled = sshEnabled }
        if let proxyEnabled = change.proxyEnabled { next.proxyEnabled = proxyEnabled }
        if let publicAddress = change.publicAddress { next.publicAddress = publicAddress }
        if let tlsIdentityPath = change.tlsIdentityPath { next.tlsIdentityPath = tlsIdentityPath }
        if let detachAgents = change.detachAgents { next.detachAgents = detachAgents }
        if let clientsKeepMessages = change.clientsKeepMessages { next.clientsKeepMessages = clientsKeepMessages }
        if change.containerEnabled != nil || change.containerCPUs != nil || change.containerMemoryGiB != nil
            || change.containerIdleMinutes != nil {
            var container = next.container ?? ContainerSettings()
            if let containerEnabled = change.containerEnabled { container.enabled = containerEnabled }
            if let problem = applyContainerResources(change, to: &container) { return problem }
            next.container = container
        }
        if next != settings { settings = next }
        if let tlsPassword = change.tlsPassword, !tlsPassword.isEmpty { setTLSPassword(tlsPassword) }
        if let password, password != self.password {
            self.password = password
            Self.log("the password was changed")
        }
        return nil
    }
}
