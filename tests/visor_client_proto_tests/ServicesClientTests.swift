// The services' clients (VisorClientGRPCClient), named as the protos name
// them, as the servers are (ServicesServerTests).

import GRPCCore
import Testing
import VisorClientGRPCClient

@Suite struct ServicesClientTests {
    @Test func testTheClientsAreNamedAsTheProtosSay() {
        #expect(Visor_Client_V1_Sessions.descriptor.fullyQualifiedService == "visor.client.v1.Sessions")
        #expect(Visor_Client_V1_Sessions.Method.Watch.descriptor.fullyQualifiedMethod == "visor.client.v1.Sessions/Watch")
        #expect(Visor_Client_V1_Sessions.Method.descriptors.map(\.method) == ["Watch", "Sync", "Earlier", "Send", "Approve", "Interrupt", "Stop"])
        // What a client of each calls.
        #expect(name((any Visor_Client_V1_Server.ClientProtocol).self).hasSuffix("ClientProtocol"))
        #expect(name((any Visor_Client_V1_Sessions.ClientProtocol).self).hasSuffix("ClientProtocol"))
    }

    private func name<T>(_ type: T.Type) -> String { String(describing: type) }
}
